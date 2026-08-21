@testmodule SchedulingHelpers begin
    using TestItemControllers: TestItemController, TestRunState, TestEnvironment, ProcessEnv,
        TestItemDetail, TestSetupDetail, TestRunItem, ControllerCallbacks

    # A controller with no live processes — enough for the assignment path, which never
    # touches the reactor.
    function make_controller(; schedule=:duration)
        callbacks = ControllerCallbacks(
            on_testitem_started = (a, b, c) -> nothing,
            on_testitem_passed = (a, b, c, d) -> nothing,
            on_testitem_failed = (a, b, c, d, e) -> nothing,
            on_testitem_errored = (a, b, c, d, e) -> nothing,
            on_testitem_skipped = (a, b, c) -> nothing,
            on_append_output = (a, b, c, d) -> nothing,
            on_attach_debugger = (a, b) -> nothing,
        )
        return TestItemController(callbacks; schedule=schedule)
    end

    const PKG = "file:///pkg"

    function make_item(id; setups=String[])
        return TestItemDetail(id, "$(PKG)/test/$(id).jl", id, "Pkg", PKG, true, collect(String, setups),
            1, 1, "@test true", 1, 1)
    end

    make_setup(name, kind) = TestSetupDetail(PKG, name, kind, "$(PKG)/test/setup.jl", 1, 1, "x = 1")

    function make_testrun(items, setups)
        env = TestEnvironment("env-1", "julia", String[], nothing,
            Dict{String,Union{String,Nothing}}(), "Normal", "Pkg", PKG, nothing, nothing, nothing)
        work_units = [TestRunItem(i.id, env.id, nothing, :Info) for i in items]
        tr = TestRunState("run-1", [env], items, work_units, setups, 4)
        return (tr, ProcessEnv(env))
    end
end

@testitem "schedule_testitems: empty inputs" begin
    using TestItemControllers: schedule_testitems, ScheduleItem

    @test schedule_testitems(ScheduleItem[], String[]) == Dict{String,Vector{String}}()
    @test schedule_testitems(ScheduleItem[], ["w1", "w2"]) ==
        Dict("w1" => String[], "w2" => String[])
    # No workers: nothing can be placed, and nothing blows up.
    @test schedule_testitems([ScheduleItem("a")], String[]) == Dict{String,Vector{String}}()
end

@testitem "schedule_testitems: plain LPT with no setups" begin
    using TestItemControllers: schedule_testitems, ScheduleItem

    items = [
        ScheduleItem("a"; duration=100.0),
        ScheduleItem("b"; duration=60.0),
        ScheduleItem("c"; duration=50.0),
        ScheduleItem("d"; duration=40.0),
    ]
    a = schedule_testitems(items, ["w1", "w2"])

    # 100 | 60+50 → then 40 goes to the lighter (100) side.
    @test sort(a["w1"]) == ["a", "d"]
    @test sort(a["w2"]) == ["b", "c"]
    @test a["w1"][1] == "a"   # longest first
end

@testitem "schedule_testitems: a heavy shared setup keeps its items together" begin
    using TestItemControllers: schedule_testitems, ScheduleItem

    # Four cheap items sharing an expensive @testmodule, plus one long item to keep the
    # other worker busy. Duplicating the setup would cost 1000ms; keeping the four
    # together costs at most 400ms of imbalance, so they must not be split.
    items = ScheduleItem[ScheduleItem("s$i"; setups=["S"], duration=100.0) for i in 1:4]
    push!(items, ScheduleItem("filler"; duration=1400.0))

    a = schedule_testitems(items, ["w1", "w2"]; setup_costs=Dict("S" => 1000.0))

    @test a["w1"] == ["filler"]
    @test sort(a["w2"]) == ["s1", "s2", "s3", "s4"]
end

@testitem "schedule_testitems: a large enough imbalance duplicates the setup" begin
    using TestItemControllers: schedule_testitems, ScheduleItem

    # Same setup cost as the clustering case, but now there is 2000ms of shared-setup work
    # against a 1400ms filler. Once the imbalance exceeds the 1000ms setup cost, paying for
    # a second copy of S really is the cheaper choice.
    items = ScheduleItem[ScheduleItem("s$(lpad(i, 2, '0'))"; setups=["S"], duration=100.0) for i in 1:20]
    push!(items, ScheduleItem("filler"; duration=1400.0))

    a = schedule_testitems(items, ["w1", "w2"]; setup_costs=Dict("S" => 1000.0))

    @test length(a["w1"]) > 1        # w1 took shared-setup items on top of the filler
    @test !isempty(a["w2"])
    @test "filler" in a["w1"]
    @test length(a["w1"]) + length(a["w2"]) == 21
end

@testitem "schedule_testitems: warm workers partition two setup families" begin
    using TestItemControllers: schedule_testitems, ScheduleItem

    # Two families of equal-cost items, one worker warm for each. The model must send
    # each family to the worker that already has its setup...
    items = vcat(
        ScheduleItem[ScheduleItem("s$i"; setups=["S"], duration=100.0) for i in 1:4],
        ScheduleItem[ScheduleItem("t$i"; setups=["T"], duration=100.0) for i in 1:4],
    )
    warm = Dict("w1" => Set(["S"]), "w2" => Set(["T"]))

    a = schedule_testitems(items, ["w1", "w2"];
        setup_costs=Dict("S" => 1000.0, "T" => 1000.0), worker_setups=warm)
    @test sort(a["w1"]) == ["s1", "s2", "s3", "s4"]
    @test sort(a["w2"]) == ["t1", "t2", "t3", "t4"]

    # ...and, with nothing to price (which is what a @testsnippet looks like once it has
    # been filtered out), fall back to plain LPT, which interleaves the two families.
    bare = ScheduleItem[ScheduleItem(i.id; duration=i.duration) for i in items]
    b = schedule_testitems(bare, ["w1", "w2"]; worker_setups=warm)
    @test sort(b["w1"]) != ["s1", "s2", "s3", "s4"]
    @test length(b["w1"]) == 4 && length(b["w2"]) == 4
end

@testitem "schedule_testitems: pooled warm setups attract their items" begin
    using TestItemControllers: schedule_testitems, ScheduleItem

    items = ScheduleItem[ScheduleItem("s$i"; setups=["S"], duration=100.0) for i in 1:3]
    push!(items, ScheduleItem("filler"; duration=100.0))

    # w2 already has S evaluated from a previous run, so reusing it costs zero.
    a = schedule_testitems(
        items, ["w1", "w2"];
        setup_costs = Dict("S" => 1000.0),
        worker_setups = Dict("w2" => Set(["S"])),
    )

    @test sort(a["w2"]) == ["s1", "s2", "s3"]
    @test a["w1"] == ["filler"]
end

@testitem "schedule_testitems: warm setups lose to a big enough imbalance" begin
    using TestItemControllers: schedule_testitems, ScheduleItem

    # Same warm worker, but now the shared-setup work dwarfs the setup cost, so the cold
    # worker eventually pays for its own copy rather than idling.
    items = ScheduleItem[ScheduleItem("s$(lpad(i, 2, '0'))"; setups=["S"], duration=1000.0) for i in 1:10]

    a = schedule_testitems(
        items, ["w1", "w2"];
        setup_costs = Dict("S" => 500.0),
        worker_setups = Dict("w2" => Set(["S"])),
    )

    @test !isempty(a["w1"])
    @test !isempty(a["w2"])
    @test length(a["w2"]) >= length(a["w1"])   # warm worker still gets no less than its share
end

@testitem "schedule_testitems: failed items spread across workers and go first" begin
    using TestItemControllers: schedule_testitems, ScheduleItem

    items = ScheduleItem[
        ScheduleItem("f1"; setups=["S"], duration=30.0, failed=true),
        ScheduleItem("f2"; setups=["S"], duration=20.0, failed=true),
        ScheduleItem("f3"; setups=["S"], duration=10.0, failed=true),
        ScheduleItem("p1"; duration=500.0),
        ScheduleItem("p2"; duration=500.0),
        ScheduleItem("p3"; duration=500.0),
    ]

    # A ruinously expensive shared setup that phase 1 deliberately ignores.
    a = schedule_testitems(items, ["w1", "w2", "w3"]; setup_costs=Dict("S" => 100_000.0))

    @test a["w1"][1] == "f1"
    @test a["w2"][1] == "f2"
    @test a["w3"][1] == "f3"
    # Every worker starts on something interesting, longest failure first.
    @test Set(vcat(values(a)...)) == Set(["f1", "f2", "f3", "p1", "p2", "p3"])
end

@testitem "schedule_testitems: unknown durations rank mid-pack" begin
    using TestItemControllers: schedule_testitems, ScheduleItem

    items = [
        ScheduleItem("long"; duration=100.0),
        ScheduleItem("unknown"),
        ScheduleItem("short"; duration=1.0),
    ]
    a = schedule_testitems(items, ["w1"])

    # mean of the known durations is 50.5, so `unknown` sorts between the two.
    @test a["w1"] == ["long", "unknown", "short"]
end

@testitem "schedule_testitems: assignment is deterministic" begin
    using TestItemControllers: schedule_testitems, ScheduleItem

    items = ScheduleItem[ScheduleItem("i$(lpad(i, 2, '0'))"; setups=(i % 3 == 0 ? ["S"] : String[]),
        duration=(i % 5 == 0 ? nothing : Float64(i * 7)), failed=(i % 7 == 0)) for i in 1:30]

    a = schedule_testitems(items, ["w1", "w2", "w3"]; setup_costs=Dict("S" => 40.0))
    b = schedule_testitems(items, ["w1", "w2", "w3"]; setup_costs=Dict("S" => 40.0))
    @test a == b
    @test sum(length, values(a)) == 30
end

@testitem "schedule_makespan reflects the union-of-setups cost model" begin
    using TestItemControllers: schedule_makespan, ScheduleItem

    items = [
        ScheduleItem("a"; setups=["S"], duration=10.0),
        ScheduleItem("b"; setups=["S"], duration=10.0),
    ]
    # S is paid once for the two items sharing it...
    @test schedule_makespan(Dict("w1" => ["a", "b"], "w2" => String[]), items;
        setup_costs=Dict("S" => 100.0)) == 120.0
    # ...and once per worker when they are split.
    @test schedule_makespan(Dict("w1" => ["a"], "w2" => ["b"]), items;
        setup_costs=Dict("S" => 100.0)) == 110.0
end

@testitem "Controller scheduling caches" begin
    using TestItemControllers: TestItemController, ControllerCallbacks,
        _record_testitem_started!, _record_testitem_result!, TestSetupEvaluatedMsg, handle!

    callbacks = ControllerCallbacks(
        on_testitem_started = (a, b, c) -> nothing,
        on_testitem_passed = (a, b, c, d) -> nothing,
        on_testitem_failed = (a, b, c, d, e) -> nothing,
        on_testitem_errored = (a, b, c, d, e) -> nothing,
        on_testitem_skipped = (a, b, c) -> nothing,
        on_append_output = (a, b, c, d) -> nothing,
        on_attach_debugger = (a, b) -> nothing,
    )
    c = TestItemController(callbacks)

    @test c.schedule == :duration
    @test isempty(c.last_status)

    # A start is recorded pessimistically, so an item that never reports back (hang,
    # crash, cancelled run) is still treated as a failure by the next run.
    _record_testitem_started!(c, "a")
    @test c.last_status["a"] == :errored
    @test !haskey(c.last_duration, "a")

    _record_testitem_result!(c, "a", :passed, 12.5)
    @test c.last_status["a"] == :passed
    @test c.last_duration["a"] == 12.5

    # A missing duration leaves the previous measurement in place.
    _record_testitem_result!(c, "a", :failed, nothing)
    @test c.last_status["a"] == :failed
    @test c.last_duration["a"] == 12.5

    handle!(c, TestSetupEvaluatedMsg("proc-1", "file:///pkg", "MySetup", 900.0, "hello"))
    @test c.setup_cost[("file:///pkg", "MySetup")] == 900.0
end

@testitem "TestItemController rejects an unknown schedule" begin
    using TestItemControllers: TestItemController, ControllerCallbacks

    callbacks = ControllerCallbacks(
        on_testitem_started = (a, b, c) -> nothing,
        on_testitem_passed = (a, b, c, d) -> nothing,
        on_testitem_failed = (a, b, c, d, e) -> nothing,
        on_testitem_errored = (a, b, c, d, e) -> nothing,
        on_testitem_skipped = (a, b, c) -> nothing,
        on_append_output = (a, b, c, d) -> nothing,
        on_attach_debugger = (a, b) -> nothing,
    )
    @test_throws ArgumentError TestItemController(callbacks; schedule=:lpt)
    @test TestItemController(callbacks; schedule=:contiguous).schedule == :contiguous
end

@testitem "Assignment: no history falls back to contiguous chunking" setup=[SchedulingHelpers] begin
    using TestItemControllers: _assign_items_to_procs!

    c = SchedulingHelpers.make_controller()
    items = [SchedulingHelpers.make_item("i$i") for i in 1:6]
    tr, penv = SchedulingHelpers.make_testrun(items, SchedulingHelpers.TestSetupDetail[])

    _assign_items_to_procs!(c, tr, penv, ["p1", "p2"])

    @test length(tr.testitem_ids_by_proc["p1"]) == 3
    @test length(tr.testitem_ids_by_proc["p2"]) == 3
    @test haskey(tr.stolen_ids_by_proc, "p1")
end

@testitem "Assignment: only @testmodule setups influence affinity" setup=[SchedulingHelpers] begin
    using TestItemControllers: _assign_items_to_procs!, TestProcessState

    # Two families of equally expensive items, one pooled process warm for each. Declared
    # as `module` setups the two families partition cleanly; declared as `snippet`s of the
    # same names they must not, because a snippet is re-evaluated into every item's scope
    # and so caches nothing.
    function assign(kind)
        c = SchedulingHelpers.make_controller()
        items = vcat(
            [SchedulingHelpers.make_item("s$i"; setups=["S"]) for i in 1:4],
            [SchedulingHelpers.make_item("t$i"; setups=["T"]) for i in 1:4],
        )
        for i in items
            c.last_duration[i.id] = 100.0
            c.last_status[i.id] = :passed
        end
        c.setup_cost[(SchedulingHelpers.PKG, "S")] = 1000.0
        c.setup_cost[(SchedulingHelpers.PKG, "T")] = 1000.0

        setups = [SchedulingHelpers.make_setup("S", kind), SchedulingHelpers.make_setup("T", kind)]
        tr, penv = SchedulingHelpers.make_testrun(items, setups)

        for pid in ("p1", "p2")
            c.test_processes[pid] = TestProcessState(pid, penv)
        end
        c.test_processes["p1"].loaded_setups[(SchedulingHelpers.PKG, "S")] = (output = "", duration = 1000.0)
        c.test_processes["p2"].loaded_setups[(SchedulingHelpers.PKG, "T")] = (output = "", duration = 1000.0)

        _assign_items_to_procs!(c, tr, penv, ["p1", "p2"])
        return tr.testitem_ids_by_proc
    end

    modular = assign("module")
    @test sort(modular["p1"]) == ["s1", "s2", "s3", "s4"]
    @test sort(modular["p2"]) == ["t1", "t2", "t3", "t4"]

    snippet = assign("snippet")
    @test length(snippet["p1"]) == 4 && length(snippet["p2"]) == 4
    @test sort(snippet["p1"]) != ["s1", "s2", "s3", "s4"]
end

@testitem "Assignment: schedule=:contiguous opts out entirely" setup=[SchedulingHelpers] begin
    using TestItemControllers: _assign_items_to_procs!

    c = SchedulingHelpers.make_controller(; schedule=:contiguous)
    items = [SchedulingHelpers.make_item("i$i") for i in 1:6]
    for (k, i) in enumerate(items)
        c.last_duration[i.id] = Float64(k) * 100
        c.last_status[i.id] = :failed
    end
    tr, penv = SchedulingHelpers.make_testrun(items, SchedulingHelpers.TestSetupDetail[])

    _assign_items_to_procs!(c, tr, penv, ["p1", "p2"])

    # Even with full history and every item failing, the chunks stay even and unordered.
    @test length(tr.testitem_ids_by_proc["p1"]) == 3
    @test length(tr.testitem_ids_by_proc["p2"]) == 3
end

@testitem "Assignment: a warm pooled process attracts its setup's items" setup=[SchedulingHelpers] begin
    using TestItemControllers: _assign_items_to_procs!, TestProcessState

    c = SchedulingHelpers.make_controller()
    items = [SchedulingHelpers.make_item("s$i"; setups=["S"]) for i in 1:3]
    push!(items, SchedulingHelpers.make_item("filler"))
    for i in items
        c.last_duration[i.id] = 100.0
        c.last_status[i.id] = :passed
    end
    c.setup_cost[(SchedulingHelpers.PKG, "S")] = 1000.0

    tr, penv = SchedulingHelpers.make_testrun(items, [SchedulingHelpers.make_setup("S", "module")])

    # p2 is a pooled process that already evaluated S in an earlier run.
    for pid in ("p1", "p2")
        c.test_processes[pid] = TestProcessState(pid, penv)
    end
    c.test_processes["p2"].loaded_setups[(SchedulingHelpers.PKG, "S")] =
        (output = "", duration = 1000.0)

    _assign_items_to_procs!(c, tr, penv, ["p1", "p2"])

    @test sort(tr.testitem_ids_by_proc["p2"]) == ["s1", "s2", "s3"]
    @test tr.testitem_ids_by_proc["p1"] == ["filler"]
end

@testitem "Assignment: previously failed items land first on distinct processes" setup=[SchedulingHelpers] begin
    using TestItemControllers: _assign_items_to_procs!

    c = SchedulingHelpers.make_controller()
    items = [SchedulingHelpers.make_item("i$i") for i in 1:6]
    for i in items
        c.last_duration[i.id] = 100.0
        c.last_status[i.id] = :passed
    end
    c.last_status["i1"] = :failed
    c.last_status["i2"] = :errored

    tr, penv = SchedulingHelpers.make_testrun(items, SchedulingHelpers.TestSetupDetail[])
    _assign_items_to_procs!(c, tr, penv, ["p1", "p2"])

    firsts = [tr.testitem_ids_by_proc["p1"][1], tr.testitem_ids_by_proc["p2"][1]]
    @test sort(firsts) == ["i1", "i2"]
end

@testitem "Assignment: processes with an existing assignment are left alone" setup=[SchedulingHelpers] begin
    using TestItemControllers: _assign_items_to_procs!

    c = SchedulingHelpers.make_controller()
    items = [SchedulingHelpers.make_item("i$i") for i in 1:4]
    tr, penv = SchedulingHelpers.make_testrun(items, SchedulingHelpers.TestSetupDetail[])

    tr.testitem_ids_by_proc["p1"] = ["i1", "i2"]
    _assign_items_to_procs!(c, tr, penv, ["p1", "p2"])

    @test tr.testitem_ids_by_proc["p1"] == ["i1", "i2"]
    @test sort(tr.testitem_ids_by_proc["p2"]) == ["i3", "i4"]
end

@testitem "Assignment: one id in two environments is assigned in both" setup=[SchedulingHelpers] begin
    using TestItemControllers: TestRunState, TestEnvironment, ProcessEnv, TestItemDetail,
        TestRunItem, TestSetupDetail, _assign_items_to_procs!

    # The same package checked out into two folders: both copies mint the same test item id,
    # and each runs under its own environment. Every environment must get the id assigned to
    # one of *its* processes. Treating a bare id as assigned because some other environment's
    # process already holds it drops the second work unit — it is never dispatched,
    # `remaining_work` never empties, and the run hangs instead of completing.
    pkg_a = "file:///a/Pkg"
    pkg_b = "file:///b/Pkg"
    id = "Pkg@aaaaaaaa/test/runtests.jl::shared"

    mkenv(env_id, pkg) = TestEnvironment(env_id, "julia", String[], nothing,
        Dict{String,Union{String,Nothing}}(), "Normal", "Pkg", pkg, nothing, nothing, nothing)
    mkitem(pkg) = TestItemDetail(id, "$(pkg)/test/runtests.jl", id, "Pkg", pkg, true, String[],
        1, 1, "@test true", 1, 1)

    env_a, env_b = mkenv("env-a", pkg_a), mkenv("env-b", pkg_b)

    c = SchedulingHelpers.make_controller()
    tr = TestRunState(
        "run-1",
        [env_a, env_b],
        [mkitem(pkg_a), mkitem(pkg_b)],
        [TestRunItem(id, "env-a", nothing, :Info), TestRunItem(id, "env-b", nothing, :Info)],
        TestSetupDetail[],
        4,
    )

    # env-b first, so that env-a is the one that used to come up empty.
    _assign_items_to_procs!(c, tr, ProcessEnv(env_b), ["p-b"])
    _assign_items_to_procs!(c, tr, ProcessEnv(env_a), ["p-a"])

    @test tr.testitem_ids_by_proc["p-b"] == [id]
    @test tr.testitem_ids_by_proc["p-a"] == [id]
end

@testitem "Scheduling history survives a second run in one session" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown,
        ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    items = filter(i -> i.label in ("add works", "greet works"), discovered.items)
    @test length(items) == 2

    passed = Dict{String,Int}()
    callbacks = ControllerCallbacks(
        on_testitem_started = (a, b, c) -> nothing,
        on_testitem_passed = (run_id, item_id, env_id, duration) -> (passed[item_id] = get(passed, item_id, 0) + 1),
        on_testitem_failed = (a, b, c, d, e) -> nothing,
        on_testitem_errored = (a, b, c, d, e) -> nothing,
        on_testitem_skipped = (a, b, c) -> nothing,
        on_append_output = (a, b, c, d) -> nothing,
        on_attach_debugger = (a, b) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    try
        for _ in 1:2
            execute_testrun(
                controller,
                string(UUIDs.uuid4()),
                [test_env],
                items,
                [TestRunItem(i.id, test_env.id, nothing, :Info) for i in items],
                discovered.setups,
                2,
                nothing,
            )
        end
    finally
        shutdown(controller)
        TestHelpers.timed_wait(controller_task, 600; label="controller")
    end

    @test all(v -> v == 2, values(passed))
    @test length(passed) == 2
    # Run 1 populated the duration cache, which run 2 scheduled against.
    for i in items
        @test haskey(controller.last_duration, i.id)
        @test controller.last_status[i.id] == :passed
    end
end
