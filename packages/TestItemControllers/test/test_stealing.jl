# Work stealing is speculative: `_check_stealing!` hands an item to the thief without
# waiting for the victim to confirm it gave the item up, and a victim already executing the
# item runs it to completion regardless. One item can therefore execute on two processes.
# These tests pin down the resulting contract: only the owning process may report on an
# item, so consumers see exactly one terminal callback and never a status going backwards.
#
# The reactor's handlers are driven directly here — no Julia worker processes are launched,
# so these are fast unit tests. `TestItemController`'s reactor channel is unbounded, so the
# `put!`s that handlers make (e.g. ReturnToPoolMsg) never block.

@testmodule StealingHelpers begin
    using TestItemControllers
    using TestItemControllers: TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        TestItemController, TestRunState, TestProcessState, ProcessEnv, ControllerCallbacks

    """A recorder for every terminal/started callback, in order."""
    struct Recorder
        events::Vector{NamedTuple{(:event, :testitem_id),Tuple{Symbol,String}}}
    end
    Recorder() = Recorder(NamedTuple{(:event, :testitem_id),Tuple{Symbol,String}}[])

    events_of(r::Recorder, kind::Symbol) = [e.testitem_id for e in r.events if e.event === kind]

    function callbacks(r::Recorder)
        record = (kind, id) -> (push!(r.events, (event=kind, testitem_id=id)); nothing)
        return ControllerCallbacks(
            on_testitem_started = (run_id, item_id, env_id) -> record(:started, item_id),
            on_testitem_passed = (run_id, item_id, env_id, duration) -> record(:passed, item_id),
            on_testitem_failed = (run_id, item_id, env_id, messages, duration) -> record(:failed, item_id),
            on_testitem_errored = (run_id, item_id, env_id, messages, duration) -> record(:errored, item_id),
            on_testitem_skipped = (run_id, item_id, env_id) -> record(:skipped, item_id),
            on_append_output = (run_id, item_id, env_id, output) -> nothing,
            on_attach_debugger = (run_id, pipe_name) -> nothing,
        )
    end

    function make_env(id::String="env-1")
        return TestEnvironment(
            id, "julia", String[], nothing,
            Dict{String,Union{String,Nothing}}(), "Run",
            "Pkg", "file:///pkg", "file:///proj", nothing
        )
    end

    function make_item(id::String)
        return TestItemDetail(id, "file:///test.jl", id, "Pkg", "file:///pkg",
            true, String[], 1, 1, "@test true", 1, 1)
    end

    """
    A run with `item_ids` all assigned to `owner_proc`, plus a second idle process, wired
    into a fresh controller. Mirrors the state the reactor reaches once processes are
    acquired and work has been dispatched.
    """
    function setup(item_ids::Vector{String}; owner_proc="proc-owner", other_proc="proc-other")
        recorder = Recorder()
        c = TestItemController(callbacks(recorder))

        env = make_env()
        items = [make_item(id) for id in item_ids]
        work_units = [TestRunItem(id, env.id, nothing, :Info) for id in item_ids]
        tr = TestRunState("run-1", [env], items, work_units, TestSetupDetail[], 2)

        tr.testitem_ids_by_proc[owner_proc] = copy(item_ids)
        tr.testitem_ids_by_proc[other_proc] = String[]
        tr.stolen_ids_by_proc[owner_proc] = String[]
        tr.stolen_ids_by_proc[other_proc] = String[]
        c.test_runs[tr.id] = tr

        pe = ProcessEnv(env)
        for pid in (owner_proc, other_proc)
            c.test_processes[pid] = TestProcessState(pid, pe)
        end

        return (; c, tr, recorder, owner_proc, other_proc, env)
    end

    """Walk the run FSM to the state it is in once work has been dispatched."""
    function advance_to_procs_acquired!(tr)
        TestItemControllers.transition!(tr.fsm, TestItemControllers.TestRunWaitingForProcs; reason="test")
        TestItemControllers.transition!(tr.fsm, TestItemControllers.TestRunProcsAcquired; reason="test")
        return nothing
    end

    """Move `item_id` from one process's queue to another's, the way `_check_stealing!` does."""
    function steal!(tr, from::String, to::String, item_id::String)
        idx = findfirst(isequal(item_id), tr.testitem_ids_by_proc[from])
        deleteat!(tr.testitem_ids_by_proc[from], idx)
        push!(tr.testitem_ids_by_proc[to], item_id)
        return nothing
    end
end

@testitem "_owns_testitem tracks assignment, steals and completion" setup=[StealingHelpers] begin
    using .StealingHelpers
    using TestItemControllers: _owns_testitem, _remove_from_proc_queue!

    ctx = StealingHelpers.setup(["item-1", "item-2"])
    tr = ctx.tr

    @test _owns_testitem(tr, ctx.owner_proc, "item-1")
    @test _owns_testitem(tr, ctx.owner_proc, "item-2")
    @test !_owns_testitem(tr, ctx.other_proc, "item-1")
    # An unknown process owns nothing rather than erroring.
    @test !_owns_testitem(tr, "no-such-proc", "item-1")

    StealingHelpers.steal!(tr, ctx.owner_proc, ctx.other_proc, "item-2")
    @test _owns_testitem(tr, ctx.other_proc, "item-2")
    @test !_owns_testitem(tr, ctx.owner_proc, "item-2")
    # The un-stolen item is unaffected.
    @test _owns_testitem(tr, ctx.owner_proc, "item-1")

    # Once a result is accepted the item leaves its owner's queue, so nobody owns it — this
    # is what makes a repeated result from the same process a no-op.
    _remove_from_proc_queue!(tr, ctx.owner_proc, "item-1")
    @test !_owns_testitem(tr, ctx.owner_proc, "item-1")
    @test !_owns_testitem(tr, ctx.other_proc, "item-1")
end

@testitem "results from a non-owning test process are discarded" setup=[StealingHelpers] begin
    using .StealingHelpers
    using TestItemControllers: handle!, TestItemStartedMsg, TestItemPassedMsg,
        TestRunCompleted, state

    ctx = StealingHelpers.setup(["item-1"])
    c, tr, rec = ctx.c, ctx.tr, ctx.recorder
    StealingHelpers.advance_to_procs_acquired!(tr)

    # The victim started item-1, then it was stolen away and given to the other process.
    # Everything the victim now reports about item-1 must be ignored.
    StealingHelpers.steal!(tr, ctx.owner_proc, ctx.other_proc, "item-1")

    handle!(c, TestItemStartedMsg(tr.id, ctx.owner_proc, "item-1"))
    @test isempty(rec.events)
    # The process is executing something, which the crash classifier needs to know...
    @test c.test_processes[ctx.owner_proc].has_started_items
    # ...but it must not become the item's timeout/crash victim.
    @test c.test_processes[ctx.owner_proc].current_testitem_id === nothing

    handle!(c, TestItemPassedMsg(tr.id, ctx.owner_proc, "item-1", 12.0, nothing))
    @test isempty(rec.events)
    # The work unit survives for the real owner, and the run is not finished.
    @test haskey(tr.remaining_work, ("item-1", ctx.env.id))
    @test isempty(tr.reported_items)
    @test state(tr.fsm) != TestRunCompleted

    # The owner reports and is believed.
    handle!(c, TestItemStartedMsg(tr.id, ctx.other_proc, "item-1"))
    handle!(c, TestItemPassedMsg(tr.id, ctx.other_proc, "item-1", 34.0, nothing))
    @test StealingHelpers.events_of(rec, :started) == ["item-1"]
    @test StealingHelpers.events_of(rec, :passed) == ["item-1"]
    @test !haskey(tr.remaining_work, ("item-1", ctx.env.id))
    @test tr.reported_items == Set(["item-1"])
end

@testitem "a repeated result from the owning process is ignored" setup=[StealingHelpers] begin
    using .StealingHelpers
    using TestItemControllers: handle!, TestItemStartedMsg, TestItemPassedMsg, TestItemFailedMsg

    ctx = StealingHelpers.setup(["item-1"])
    c, tr, rec = ctx.c, ctx.tr, ctx.recorder
    StealingHelpers.advance_to_procs_acquired!(tr)

    handle!(c, TestItemStartedMsg(tr.id, ctx.owner_proc, "item-1"))
    handle!(c, TestItemPassedMsg(tr.id, ctx.owner_proc, "item-1", 5.0, nothing))
    @test StealingHelpers.events_of(rec, :passed) == ["item-1"]

    # The run has completed, so these are dropped by the FSM guard; the point is that the
    # status cannot be walked backwards or double-counted.
    handle!(c, TestItemStartedMsg(tr.id, ctx.owner_proc, "item-1"))
    handle!(c, TestItemFailedMsg(tr.id, ctx.owner_proc, "item-1", Any[], 5.0))
    @test StealingHelpers.events_of(rec, :started) == ["item-1"]
    @test StealingHelpers.events_of(rec, :passed) == ["item-1"]
    @test isempty(StealingHelpers.events_of(rec, :failed))
end

@testitem "a late start cannot walk a resolved item back to running" setup=[StealingHelpers] begin
    using .StealingHelpers
    using TestItemControllers: handle!, TestItemStartedMsg, TestItemPassedMsg

    # The observed failure: a run reported "completed" with one item still "running" — and
    # that item had a duration recorded, which only a terminal result sets. So its result had
    # arrived and been applied, then a second process (which had also been executing it after
    # a speculative steal) sent its own "started" afterwards and the consumer moved the item
    # back to running. Two items here so the run stays in progress and the FSM's
    # already-completed guard cannot be what saves us.
    ctx = StealingHelpers.setup(["item-1", "item-2"])
    c, tr, rec = ctx.c, ctx.tr, ctx.recorder
    StealingHelpers.advance_to_procs_acquired!(tr)

    # item-1 is stolen away to the other process, which runs it and reports.
    StealingHelpers.steal!(tr, ctx.owner_proc, ctx.other_proc, "item-1")
    handle!(c, TestItemStartedMsg(tr.id, ctx.other_proc, "item-1"))
    handle!(c, TestItemPassedMsg(tr.id, ctx.other_proc, "item-1", 2.6562, nothing))
    @test StealingHelpers.events_of(rec, :passed) == ["item-1"]

    # The original process had also started item-1 before the steal reached it, and its
    # "started" arrives now. It must not be forwarded.
    handle!(c, TestItemStartedMsg(tr.id, ctx.owner_proc, "item-1"))
    @test StealingHelpers.events_of(rec, :started) == ["item-1"]
    @test last(rec.events).event === :passed

    # Nor may its own terminal result be forwarded a second time.
    handle!(c, TestItemPassedMsg(tr.id, ctx.owner_proc, "item-1", 9.9, nothing))
    @test StealingHelpers.events_of(rec, :passed) == ["item-1"]

    # The run is still in progress and item-2 is unaffected by any of it.
    @test haskey(tr.remaining_work, ("item-2", ctx.env.id))
    @test tr.reported_items == Set(["item-1"])
end

@testitem "a completing run reports items that never produced a result" setup=[StealingHelpers] begin
    using .StealingHelpers
    using TestItemControllers: _check_all_items_reported

    ctx = StealingHelpers.setup(["item-1", "item-2"])
    tr = ctx.tr

    # Nothing reported yet: both items are flagged, loudly.
    unreported = @test_logs (:error,) _check_all_items_reported(tr)
    @test Set(unreported) == Set(["item-1", "item-2"])

    push!(tr.reported_items, "item-1")
    @test (@test_logs (:error,) _check_all_items_reported(tr)) == ["item-2"]

    # The healthy case must be silent — every integration test in this suite relies on that
    # to act as a regression check.
    push!(tr.reported_items, "item-2")
    @test isempty(_check_all_items_reported(tr))
    @test_logs _check_all_items_reported(tr)
end
