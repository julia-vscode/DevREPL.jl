@testitem "GC between test items does not deadlock the test process" setup=[TestHelpers] begin
    # Regression test for a deadlock that shipped with the watchdog and sat on the common
    # path: `gc_between_testitems` defaults on for multi-process runs.
    #
    # The watchdog thread runs a loop that neither allocates nor yields, paced by
    # `Libc.systemsleep` (a plain `ccall`). Without an explicit `GC.safepoint()` the thread
    # never becomes collectable, so `GC.gc(true)` — which stops the world and waits for
    # every thread — blocks forever on the first inter-item collection. The process then
    # stops consuming items and the run wedges with no diagnostic at all.
    #
    # Several passing items matter: the deadlock strikes on the *second*, after the first
    # has triggered a collection. The run timeout turns a regression into a failure rather
    # than a hang.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label in ("add works", "greet works", "output test"), discovered.items)
    @test length(items) == 3

    result = TestHelpers.run_testrun(
        items, discovered.setups, discovered;
        gc_between_testitems=true, timeout=180,
    )

    passed = filter(e -> e.event == :passed, result.events)
    @test length(passed) == 3
    @test isempty(filter(e -> e.event in (:failed, :errored), result.events))
end

@testitem "GC between test items stays off unless requested" setup=[TestHelpers] begin
    # The flag has to actually reach the test process for the test above to mean anything,
    # so pin both directions rather than only the enabled one.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "add works", discovered.items)

    result = TestHelpers.run_testrun(
        items, discovered.setups, discovered;
        gc_between_testitems=false, timeout=600,
    )

    @test length(filter(e -> e.event == :passed, result.events)) == 1
end

@testitem "A timed-out test item leaves hang diagnostics in its output" setup=[TestHelpers] begin
    # The point of the watchdog: an item killed for running too long should leave a stack
    # behind rather than a bare "timed out" line. The dump is written to a private file by a
    # dedicated thread and folded into the item's output by the controller, so asserting on
    # the captured output exercises that whole path.
    #
    # `slow test` sleeps, which still yields — the case the watchdog can serve. An item that
    # neither allocates nor yields never reaches a safepoint and is explicitly out of scope;
    # the controller's own timeout remains the backstop there.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    slow = only(filter(i -> i.label == "slow test", discovered.items))

    result = TestHelpers.run_testrun(
        [slow], discovered.setups, discovered;
        timeout=180, item_timeouts=Dict(slow.id => 5.0),
    )

    errored = filter(e -> e.testitem_id == slow.id && e.event == :errored, result.events)
    @test length(errored) == 1

    output = get(result.outputs, slow.id, "")
    @test occursin("Hang diagnostics", output)
    # The header carries the item and the process context, which is what makes the dump
    # actionable when it turns up in a CI log.
    @test occursin(slow.label, output)
    @test occursin("Julia ", output)
    # The dump must carry actual evidence, not just a header. The profile capture shipped
    # broken on 1.12 (a world-age error swallowed into "No CPU profile: ...") while this test
    # stayed green because it only checked the header. Task backtraces are what locate a
    # *blocked* task; the profile only ever shows running code. Assert on positive markers:
    # the dump is written in sections, so a section that never made it to disk would leave
    # no "No ..." line to check for. `Root task` is printed by the runtime's task dump and
    # `Overhead` heads `Profile.print`'s tree.
    @test occursin("Task backtraces", output)
    @test occursin("Root task", output)
    @test occursin("CPU profile", output)
    @test occursin("Overhead", output)
    @test !occursin("No CPU profile", output)
    @test !occursin("No task backtraces", output)
end

@testitem "A test process over the memory threshold is recycled without losing items" setup=[TestHelpers] begin
    # The worker checks system memory after each item and, when over threshold, exits
    # cleanly with a distinguished code instead of being killed. The controller has to treat
    # that as a recycle — redistributing un-started items through the existing termination
    # path — rather than as a crash.
    #
    # A threshold of 0.0 means "always over", so every item recycles its process. That is
    # the harshest form of the path, and it pins the invariant that matters: every item
    # still reports exactly once, and nothing is reported as an error.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label in ("add works", "greet works", "output test"), discovered.items)

    result = TestHelpers.run_testrun(
        items, discovered.setups, discovered;
        memory_threshold=0.0, timeout=300,
    )

    passed = filter(e -> e.event == :passed, result.events)
    @test Set(e.testitem_id for e in passed) == Set(i.id for i in items)
    @test length(passed) == length(items)
    @test isempty(filter(e -> e.event in (:failed, :errored), result.events))

    # Without this the test is vacuous: three items pass whether or not a single recycle
    # happened. Each item recycles its process, so the run needs more processes than the
    # one it started with.
    created = filter(e -> e.event == :process_created, result.process_events)
    @test length(created) > 1
end

@testitem "A recycling test process exits without stranding the controller" setup=[TestHelpers] begin
    # Regression test. `exit` tears the runtime down from the calling thread, so exiting
    # while the watchdog was still running Julia code raced it: on Windows that surfaced as
    # an `EXCEPTION_ACCESS_VIOLATION` inside the JIT, and otherwise as a process that never
    # exited — which stranded the controller in shutdown, waiting for a termination message
    # that could not arrive. The run itself completed, so only the shutdown hung, which is
    # why the three-item test above did not catch it.
    #
    # Two items on one process is the shape that reproduced: exactly one recycle, then a
    # replacement that finishes the run and is shut down normally. The assertion that
    # matters is simply that this returns at all.
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label in ("add works", "greet works"), discovered.items)
    @test length(items) == 2

    result = TestHelpers.run_testrun(
        items, discovered.setups, discovered;
        memory_threshold=0.0, max_procs=1, timeout=180,
    )

    @test length(filter(e -> e.event == :passed, result.events)) == 2
    @test isempty(filter(e -> e.event in (:failed, :errored), result.events))
end

@testitem "Shutdown stops within its grace period when a process never reports termination" setup=[TestHelpers] begin
    # The reactor leaves `ControllerShuttingDown` only when every tracked process has posted
    # a `TestProcessTerminatedMsg`. A process whose IO task has wedged never posts one, and
    # before the shutdown deadline existed that kept `run(controller)` from ever returning —
    # a CI item then hung until the runner's 20 minute watchdog killed it, with nothing to
    # show for it. Model the wedge directly: a tracked process with no IO task at all.
    using TestItemControllers: TestItemController, ControllerCallbacks, TestProcessState, ProcessEnv,
        shutdown, state, ControllerStopped, ProcessDead

    terminated = String[]
    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> nothing,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> nothing,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> nothing,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
        on_process_terminated = id -> push!(terminated, id),
    )

    controller = TestItemController(callbacks; shutdown_grace_seconds=1.0)

    env = ProcessEnv("file:///project", "file:///package", "MyPkg", "julia", String[], nothing, "Run",
        Dict{String,Union{String,Nothing}}())
    ps = TestProcessState("stuck-proc", env)
    controller.test_processes[ps.id] = ps
    controller.process_pool[env] = [ps.id]

    controller_task = @async run(controller)
    shutdown(controller)

    # Well under the old "forever", comfortably over the 1s grace.
    TestHelpers.timed_wait(controller_task, 15; label="controller shutdown with a stuck process")

    @test state(controller.controller_fsm) == ControllerStopped
    @test isempty(controller.test_processes)
    @test isempty(controller.process_pool[env])
    @test state(ps.fsm) == ProcessDead
    @test terminated == ["stuck-proc"]
    @test controller.shutdown_timer === nothing
end

@testitem "Shutdown does not wait out the grace period when processes report normally" setup=[TestHelpers] begin
    # The deadline is a backstop, not a delay: a normal shutdown must still stop the moment
    # the last process is gone, and must disarm the timer so it cannot fire into a stopped
    # controller.
    using TestItemControllers: TestItemController, ControllerCallbacks, TestProcessState, ProcessEnv,
        TestProcessTerminatedMsg, shutdown, state, ControllerStopped

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> nothing,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> nothing,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> nothing,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    controller = TestItemController(callbacks; shutdown_grace_seconds=60.0)

    env = ProcessEnv("file:///project", "file:///package", "MyPkg", "julia", String[], nothing, "Run",
        Dict{String,Union{String,Nothing}}())
    ps = TestProcessState("proc-1", env)
    controller.test_processes[ps.id] = ps

    controller_task = @async run(controller)
    shutdown(controller)
    # Stand in for the IO task: report the termination ourselves.
    put!(controller.reactor_channel, TestProcessTerminatedMsg(ps.id, nothing, false))

    t0 = time()
    TestHelpers.timed_wait(controller_task, 15; label="controller shutdown")
    @test time() - t0 < 30  # i.e. it did not sit out the 60s grace

    @test state(controller.controller_fsm) == ControllerStopped
    @test isempty(controller.test_processes)
    @test controller.shutdown_timer === nothing
end

@testitem "A slow environment activation is reported while it is still running" setup=[TestHelpers] begin
    # Activation covers the test process's own precompilation, so it can legitimately take
    # minutes. Until it answers, the controller has nothing to say beyond the "Activating"
    # status it posted at the start — which is how a per-version platform item that stalled
    # in activation on macOS produced a job log naming neither the stage nor the process.
    #
    # The interval is dialled down to a fraction of a second so a *normal* activation, which
    # spends well over that launching and loading the test server, trips it.
    using Logging: with_logger, Warn
    using Test: TestLogger

    discovered = TestHelpers.basic_package_discovery()
    items = filter(i -> i.label == "add works", discovered.items)
    @test length(items) == 1

    logger = TestLogger(min_level=Warn)
    result = with_logger(logger) do
        TestHelpers.run_testrun(items, discovered.setups, discovered; activation_progress_seconds=0.05)
    end

    @test length(filter(e -> e.event == :passed, result.events)) == 1

    pending = filter(r -> r.message == "Environment activation still pending", logger.logs)
    @test !isempty(pending)
    # It names what is slow, not just that something is.
    @test haskey(first(pending).kwargs, :testprocess_id)
    @test first(pending).kwargs[:elapsed_seconds] > 0
end

@testitem "activation_progress_seconds must be positive" setup=[TestHelpers] begin
    import TestItemControllers
    using TestItemControllers: TestItemController, ControllerCallbacks

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> nothing,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> nothing,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> nothing,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    @test_throws ArgumentError TestItemController(callbacks; activation_progress_seconds=0)
    @test TestItemController(callbacks).activation_progress_seconds ==
        TestItemControllers.DEFAULT_ACTIVATION_PROGRESS_SECONDS
end
