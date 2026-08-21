@testitem "Controller shutdown with active processes" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    passing_items = filter(i -> i.label == "add works", discovered.items)

    result = TestHelpers.run_testrun(passing_items, discovered.setups, discovered)

    # Test run should complete successfully
    passed_events = filter(e -> e.event == :passed, result.events)
    @test length(passed_events) == 1

    # Process should have been created and eventually become idle
    created_events = filter(e -> e.event == :process_created, result.process_events)
    @test length(created_events) >= 1
end

@testitem "Terminate specific test process" begin
    using TestItemControllers: ControllerCallbacks

    process_events = NamedTuple[]

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> nothing,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> nothing,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> nothing,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> nothing,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
        on_process_created = (id, test_env_id) -> push!(process_events, (event=:created, id=id)),
        on_process_terminated = id -> push!(process_events, (event=:terminated, id=id)),
    )

    tic = TestItemController(callbacks; log_level=:Debug)

    controller_finished = Channel(1)

    @async try
        run(tic)
        put!(controller_finished, true)
    catch err
        Base.display_error(err, catch_backtrace())
    end

    # No processes exist yet, so terminate_test_process should be a no-op
    terminate_test_process(tic, "nonexistent-id")

    shutdown(tic)
    @test fetch(controller_finished)
end

@testitem "A second shutdown request is a no-op, not a reactor crash" begin
    using TestItemControllers: TestItemController, ControllerCallbacks, shutdown, ShutdownMsg

    # `handle!(::ShutdownMsg)` used to drive the controller FSM ShuttingDown → ShuttingDown
    # on a repeat request, which throws — and an exception on the reactor does not fail
    # anything visibly, it kills the loop and every run in flight hangs until its caller
    # times out. A test harness that called `shutdown` on its timeout path *and* on the way
    # out did exactly that, turning a slow run into a wedged controller.
    callbacks = ControllerCallbacks(
        on_testitem_started = (a, b, c) -> nothing,
        on_testitem_passed = (a, b, c, d) -> nothing,
        on_testitem_failed = (a, b, c, d, e) -> nothing,
        on_testitem_errored = (a, b, c, d, e) -> nothing,
        on_testitem_skipped = (a, b, c) -> nothing,
        on_append_output = (a, b, c, d) -> nothing,
        on_attach_debugger = (a, b) -> nothing,
    )
    controller = TestItemController(callbacks)
    task = @async run(controller)

    shutdown(controller)
    shutdown(controller)   # must be harmless

    # The reactor must have exited cleanly, not by exception.
    wait(task)
    @test istaskdone(task)
    @test !istaskfailed(task)
end
