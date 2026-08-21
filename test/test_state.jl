@testitem "TestProcessState construction defaults" begin
    using TestItemControllers: TestProcessState, ProcessEnv, state, ProcessCreated, CancellationTokens

    env = ProcessEnv(
        "file:///project",
        "file:///package",
        "MyPkg",
        "julia",
        String[],
        nothing,
        "Run",
        Dict{String,Union{String,Nothing}}()
    )

    ps = TestProcessState("proc-1", env)

    @test ps.id == "proc-1"
    @test state(ps.fsm) == ProcessCreated
    @test ps.env === env
    @test ps.testrun_id === nothing
    @test ps.jl_process === nothing
    @test ps.endpoint === nothing
    @test ps.current_testitem_id === nothing
    @test ps.current_testitem_started_at === nothing
    @test ps.timeout_cs === nothing
    @test ps.timeout_reg === nothing
    @test ps.termination_reg === nothing
    @test isempty(ps.process_tasks)
    @test ps.is_precompile_process == false
    @test ps.precompile_done == false
    @test ps.test_env_content_hash === nothing
    @test ps.testrun_token === nothing
    @test ps.testrun_watcher_registration === nothing
    @test ps.test_setups === nothing
    @test ps.coverage_root_uris === nothing
    @test ps.proc_log_level == :Info
    # debug_pipe_name should be a non-empty string
    @test !isempty(ps.debug_pipe_name)
    # cs should be a valid CancellationTokenSource
    @test !CancellationTokens.is_cancellation_requested(CancellationTokens.get_token(ps.cs))
end

@testitem "TestProcessState precompile options" begin
    using TestItemControllers: TestProcessState, ProcessEnv, state, ProcessCreated

    env = ProcessEnv(
        nothing,
        "file:///package",
        "MyPkg",
        "julia",
        String[],
        nothing,
        "Run",
        Dict{String,Union{String,Nothing}}()
    )

    # With precompile options
    ps = TestProcessState("proc-2", env;
        is_precompile_process=true,
        precompile_done=true,
        test_env_content_hash="abc123"
    )

    @test ps.is_precompile_process == true
    @test ps.precompile_done == true
    @test ps.test_env_content_hash == "abc123"
    @test state(ps.fsm) == ProcessCreated
end

@testitem "TestRunState construction" begin
    using TestItemControllers: TestRunState, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        state, TestRunCreated, CancellationTokens

    test_env = TestEnvironment(
        "env-1", "julia", String[], nothing,
        Dict{String,Union{String,Nothing}}(), "Run",
        "Pkg", "file:///pkg", "file:///proj", nothing
    )

    items = [
        TestItemDetail("item-1", "file:///test.jl", "test1",
            "Pkg", "file:///pkg", true, String[], 1, 1, "@test true", 1, 1),
        TestItemDetail("item-2", "file:///test.jl", "test2",
            "Pkg", "file:///pkg", true, String[], 5, 1, "@test false", 5, 1),
    ]

    work_units = [
        TestRunItem("item-1", "env-1", nothing, :Info),
        TestRunItem("item-2", "env-1", nothing, :Info),
    ]

    setups = TestSetupDetail[]

    rs = TestRunState("run-1", [test_env], items, work_units, setups, 1)

    @test rs.id == "run-1"
    @test state(rs.fsm) == TestRunCreated
    @test length(rs.test_environments) == 1
    @test length(rs.remaining_work) == 2
    @test haskey(rs.remaining_work, ("item-1", "env-1"))
    @test haskey(rs.remaining_work, ("item-2", "env-1"))
    # Keyed by `(id, package_uri)`: an id alone does not identify an item when the same
    # package is checked out into two folders of one workspace.
    @test rs.test_items[("item-1", "env-1")].label == "test1"
    @test isempty(rs.test_setups)
    @test rs.procs === nothing
    @test isempty(rs.testitem_ids_by_proc)
    @test isempty(rs.stolen_ids_by_proc)
    @test isempty(rs.items_dispatched_to_procs)
    @test isempty(rs.processes_ready_before_acquired)
    @test isempty(rs.coverage)
    # completion_channel should be open
    @test isopen(rs.completion_channel)
end

@testitem "TestRunState with cancellation token" begin
    using TestItemControllers: TestRunState, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        CancellationTokens

    test_env = TestEnvironment(
        "env-1", "julia", String[], nothing,
        Dict{String,Union{String,Nothing}}(), "Run",
        "Pkg", "file:///pkg", "file:///proj", nothing
    )

    items = [
        TestItemDetail("item-1", "file:///test.jl", "test1",
            "Pkg", "file:///pkg", true, String[], 1, 1, "@test true", 1, 1),
    ]

    work_units = [TestRunItem("item-1", "env-1", nothing, :Info)]

    parent_cs = CancellationTokens.CancellationTokenSource()
    parent_token = CancellationTokens.get_token(parent_cs)

    rs = TestRunState("run-linked", [test_env], items, work_units, TestSetupDetail[], 1; token=parent_token)

    # Cancelling the parent should propagate to the run's cancellation source
    @test !CancellationTokens.is_cancellation_requested(CancellationTokens.get_token(rs.cancellation_source))
    CancellationTokens.cancel(parent_cs)
    @test CancellationTokens.is_cancellation_requested(CancellationTokens.get_token(rs.cancellation_source))
end

@testitem "TestRunState without cancellation token" begin
    using TestItemControllers: TestRunState, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        CancellationTokens

    test_env = TestEnvironment(
        "env-1", "julia", String[], nothing,
        Dict{String,Union{String,Nothing}}(), "Run",
        "", "", nothing, nothing
    )

    rs = TestRunState("run-no-token", [test_env], TestItemDetail[], TestRunItem[], TestSetupDetail[], 1)

    # Should have its own independent cancellation source
    @test !CancellationTokens.is_cancellation_requested(CancellationTokens.get_token(rs.cancellation_source))
end

@testitem "Terminal callbacks accept an optional trailing argument" begin
    using TestItemControllers: ControllerCallbacks, PerfStats,
        _notify_testitem_passed, _notify_testitem_failed, _notify_testitem_errored,
        _notify_testitem_skipped

    seen = Any[]

    # Callbacks written against the original arities must keep working untouched.
    old = ControllerCallbacks(
        on_testitem_started = (a, b, c) -> nothing,
        on_testitem_passed = (a, b, c, d) -> push!(seen, (:passed, 4)),
        on_testitem_failed = (a, b, c, d, e) -> push!(seen, (:failed, 5)),
        on_testitem_errored = (a, b, c, d, e) -> push!(seen, (:errored, 5)),
        on_testitem_skipped = (a, b, c) -> push!(seen, (:skipped, 3)),
        on_append_output = (a, b, c, d) -> nothing,
        on_attach_debugger = (a, b) -> nothing,
    )

    perf = PerfStats(1.0, 2, 3, 4.0, nothing, nothing)
    _notify_testitem_passed(old, "run", "item", "env", 1.0, perf)
    _notify_testitem_failed(old, "run", "item", "env", [], 1.0, perf)
    _notify_testitem_errored(old, "run", "item", "env", [], 1.0, perf)
    _notify_testitem_skipped(old, "run", "item", "env", "skip=true")

    @test seen == [(:passed, 4), (:failed, 5), (:errored, 5), (:skipped, 3)]

    # Callbacks that opt in get the extra argument.
    extras = Any[]
    new = ControllerCallbacks(
        on_testitem_started = (a, b, c) -> nothing,
        on_testitem_passed = (a, b, c, d, p) -> push!(extras, p),
        on_testitem_failed = (a, b, c, d, e, p) -> push!(extras, p),
        on_testitem_errored = (a, b, c, d, e, p) -> push!(extras, p),
        on_testitem_skipped = (a, b, c, r) -> push!(extras, r),
        on_append_output = (a, b, c, d) -> nothing,
        on_attach_debugger = (a, b) -> nothing,
    )

    _notify_testitem_passed(new, "run", "item", "env", 1.0, perf)
    _notify_testitem_failed(new, "run", "item", "env", [], 1.0, perf)
    _notify_testitem_errored(new, "run", "item", "env", [], 1.0, nothing)
    _notify_testitem_skipped(new, "run", "item", "env", "skip=true")

    @test extras == [perf, perf, nothing, "skip=true"]

    # And the default — no trailing argument supplied at all.
    _notify_testitem_passed(new, "run", "item", "env", 1.0)
    @test extras[end] === nothing
end

@testitem "TestProcessState starts with no loaded setups" begin
    using TestItemControllers: TestProcessState, ProcessEnv

    env = ProcessEnv(
        "file:///project",
        "file:///mypkg",
        "MyPkg",
        "julia",
        String[],
        nothing,
        "Run",
        Dict{String,Union{String,Nothing}}()
    )
    ps = TestProcessState("proc-1", env)

    @test isempty(ps.loaded_setups)
    ps.loaded_setups[("file:///mypkg", "MySetup")] = (output="hello", duration=12.0)
    @test ps.loaded_setups[("file:///mypkg", "MySetup")].output == "hello"
    @test ps.loaded_setups[("file:///mypkg", "MySetup")].duration == 12.0
end

@testitem "Stale setup cache is dropped when a run redefines or removes a setup" begin
    using TestItemControllers: TestProcessState, ProcessEnv, _setup_testrun_on_process!,
        TestItemServerProtocol

    env = ProcessEnv(
        "file:///project", "file:///package", "MyPkg", "julia", String[], nothing, "Run",
        Dict{String,Union{String,Nothing}}()
    )
    ps = TestProcessState("proc-1", env)

    setup(name, code) = TestItemServerProtocol.TestsetupDetails(
        packageUri = "file:///package", name = name, kind = "module",
        uri = "file:///package/test/setups.jl", line = 1, column = 1, code = code,
    )

    unchanged = setup("Unchanged", "const X = 1")
    edited_before = setup("Edited", "const Y = 1")
    dropped = setup("Dropped", "const Z = 1")

    # First run: three setups ship, and the process reports having evaluated all of them.
    _setup_testrun_on_process!(ps, "run-1", [unchanged, edited_before, dropped], nothing, :Info, nothing)
    for n in ("Unchanged", "Edited", "Dropped")
        ps.loaded_setups[("file:///package", n)] = (output = "", duration = 100.0)
    end

    # Second run: one setup is untouched, one has new code, one is gone entirely.
    _setup_testrun_on_process!(ps, "run-2", [unchanged, setup("Edited", "const Y = 2")], nothing, :Info, nothing)

    # The untouched setup is still warm on this process, so its measured cost still applies.
    @test haskey(ps.loaded_setups, ("file:///package", "Unchanged"))
    # The edited one will be re-evaluated by the test process; the old cost no longer
    # describes it, and keeping it would let the scheduler price affinity it cannot deliver.
    @test !haskey(ps.loaded_setups, ("file:///package", "Edited"))
    @test !haskey(ps.loaded_setups, ("file:///package", "Dropped"))
end

@testitem "Setup cache survives a run that ships identical setups" begin
    using TestItemControllers: TestProcessState, ProcessEnv, _setup_testrun_on_process!,
        TestItemServerProtocol

    env = ProcessEnv(
        "file:///project", "file:///package", "MyPkg", "julia", String[], nothing, "Run",
        Dict{String,Union{String,Nothing}}()
    )
    ps = TestProcessState("proc-1", env)

    s = TestItemServerProtocol.TestsetupDetails(
        packageUri = "file:///package", name = "Warm", kind = "module",
        uri = "file:///package/test/setups.jl", line = 1, column = 1, code = "const X = 1",
    )

    _setup_testrun_on_process!(ps, "run-1", [s], nothing, :Info, nothing)
    ps.loaded_setups[("file:///package", "Warm")] = (output = "hi", duration = 250.0)
    _setup_testrun_on_process!(ps, "run-2", [s], nothing, :Info, nothing)

    # The whole point of pooling: an unchanged setup stays warm across runs and costs
    # nothing to reuse, which is what the scheduler's affinity model is built on.
    @test ps.loaded_setups[("file:///package", "Warm")].duration == 250.0
end

@testitem "Items are found when the env spells the package uri differently" begin
    using TestItemControllers: TestRunState, TestEnvironment, TestItemDetail, TestRunItem,
        TestSetupDetail

    # This is what broke CI on Windows and nowhere else. The items' package uri comes from
    # discovery; the environment's is built straight from a path. One folder has more than
    # one valid spelling — an 8.3 short path (`C:/Users/RUNNER~1/...` on a GitHub runner),
    # either drive-letter case — so the two producers need not agree, and matching them by
    # string equality found nothing: no items were assigned and the run simply never
    # finished. It passed on Linux, which has no drive letters or short paths, and on any
    # Windows machine whose username is short enough not to get an 8.3 alias.
    env = TestEnvironment(
        "env-1", "julia", String[], nothing, Dict{String,Union{String,Nothing}}(),
        "Run", "MyPkg", "file:///C%3A/Users/RUNNER~1/AppData/Local/Temp/jl_x/pkg",
        nothing, nothing,
    )
    items = [TestItemDetail(
        "MyPkg@a1b2c3d4/test/a.jl::x",
        "file:///c%3A/Users/runneradmin/AppData/Local/Temp/jl_x/pkg/test/a.jl",
        "x", "MyPkg", "file:///c%3A/Users/runneradmin/AppData/Local/Temp/jl_x/pkg",
        true, String[], 1, 1, "@test true", 1, 1,
    )]
    work = [TestRunItem("MyPkg@a1b2c3d4/test/a.jl::x", "env-1", nothing, :Info)]

    rs = TestRunState("run-1", [env], items, work, TestSetupDetail[], 1)

    # Keyed by the environment id, so the disagreeing uris never have to be compared.
    @test length(rs.test_items) == 1
    @test rs.test_items[("MyPkg@a1b2c3d4/test/a.jl::x", "env-1")].code == "@test true"
end

@testitem "Two checkouts of one package keep their own test items" begin
    using TestItemControllers: TestRunState, TestEnvironment, TestItemDetail, TestRunItem,
        TestSetupDetail

    # Ids are scoped to their package, so two worktrees of the same package mint the same id.
    # Keyed by id alone these collapsed into one entry, and the survivor's source then ran
    # twice while the other item never ran at all.
    id = "MyPkg@a1b2c3d4/test/a.jl::shared"
    envs = [
        TestEnvironment("env-a", "julia", String[], nothing, Dict{String,Union{String,Nothing}}(),
            "Run", "MyPkg", "file:///wt/a", nothing, nothing),
        TestEnvironment("env-b", "julia", String[], nothing, Dict{String,Union{String,Nothing}}(),
            "Run", "MyPkg", "file:///wt/b", nothing, nothing),
    ]
    items = [
        TestItemDetail(id, "file:///wt/a/test/a.jl", "shared", "MyPkg", "file:///wt/a",
            true, String[], 1, 1, "@test true", 1, 1),
        TestItemDetail(id, "file:///wt/b/test/a.jl", "shared", "MyPkg", "file:///wt/b",
            true, String[], 1, 1, "@test false", 1, 1),
    ]
    work = [TestRunItem(id, "env-a", nothing, :Info), TestRunItem(id, "env-b", nothing, :Info)]

    rs = TestRunState("run-1", envs, items, work, TestSetupDetail[], 2)

    @test length(rs.test_items) == 2
    # Each checkout keeps its own source, which is the whole point. Disambiguating them is
    # the one case that genuinely needs the package uri, and it is reached only when a single
    # id names more than one item.
    @test rs.test_items[(id, "env-a")].code == "@test true"
    @test rs.test_items[(id, "env-b")].code == "@test false"
end

@testitem "A run with two indistinguishable test items is rejected" begin
    using TestItemControllers: TestItemDetail, _assert_addressable_items

    # Should be unreachable — discovery already suffixes duplicate labels within a file with
    # `#N`. The assertion exists so a future mistake in the id scheme surfaces here instead
    # of as a test item that quietly stopped running.
    items = [
        TestItemDetail("same", "file:///pkg/test/a.jl", "one", "Pkg", "file:///pkg",
            true, String[], 1, 1, "@test true", 1, 1),
        TestItemDetail("same", "file:///pkg/test/a.jl", "two", "Pkg", "file:///pkg",
            true, String[], 9, 1, "@test true", 9, 1),
    ]

    @test_throws ArgumentError _assert_addressable_items(items)
    # Distinct packages are fine: that is two checkouts, not a duplicate.
    @test _assert_addressable_items(items[1:1]) === nothing
end
