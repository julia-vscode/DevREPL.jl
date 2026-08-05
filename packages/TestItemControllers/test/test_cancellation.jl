@testitem "Cancel running test run" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        execute_testrun, shutdown, CancellationTokens, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    events = NamedTuple[]
    events_lock = ReentrantLock()

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:started, testitem_id=item_id)); end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do; push!(events, (event=:passed, testitem_id=item_id)); end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do; push!(events, (event=:failed, testitem_id=item_id)); end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do; push!(events, (event=:errored, testitem_id=item_id)); end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:skipped, testitem_id=item_id)); end,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    testrun_id = string(UUIDs.uuid4())

    cs = CancellationTokens.CancellationTokenSource()
    token = CancellationTokens.get_token(cs)

    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in discovered.items]

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    testrun_task = @async try
        execute_testrun(
            controller,
            testrun_id,
            [test_env],
            discovered.items,
            work_units,
            discovered.setups,
            1,
            token
        )
    catch err
        @error "Test run error" exception=(err, catch_backtrace())
    end

    # Cancel immediately
    CancellationTokens.cancel(cs)

    # Wait for testrun to complete
    @info "[test] Cancel running test run: waiting for testrun"
    TestHelpers.timed_wait(testrun_task, 120; label="cancel-testrun")

    @info "[test] Cancel running test run: shutting down"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 120; label="cancel-controller")

    # After cancellation, items should be skipped or already completed
    completed = filter(e -> e.event in (:passed, :failed, :errored, :skipped), events)
    @test length(completed) == length(discovered.items)
end

@testitem "Cancel test run during process activation does not crash controller" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        execute_testrun, shutdown, CancellationTokens, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    events = NamedTuple[]
    events_lock = ReentrantLock()

    controller_error = Ref{Any}(nothing)

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:started, testitem_id=item_id)); end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do; push!(events, (event=:passed, testitem_id=item_id)); end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do; push!(events, (event=:failed, testitem_id=item_id)); end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do; push!(events, (event=:errored, testitem_id=item_id)); end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:skipped, testitem_id=item_id)); end,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    # Use multiple processes to increase likelihood of hitting intermediate states
    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)

    # --- First run: cancel immediately to trigger cancellation during activation ---
    cs1 = CancellationTokens.CancellationTokenSource()
    token1 = CancellationTokens.get_token(cs1)
    testrun_id1 = string(UUIDs.uuid4())
    work_units1 = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in discovered.items]

    controller_task = @async try
        run(controller)
    catch err
        controller_error[] = err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    testrun_task1 = @async try
        execute_testrun(
            controller,
            testrun_id1,
            [test_env],
            discovered.items,
            work_units1,
            discovered.setups,
            3,  # request multiple procs to maximize activation-phase coverage
            token1
        )
    catch err
        @error "Test run 1 error" exception=(err, catch_backtrace())
    end

    # Cancel while processes are likely still in activation/starting states
    CancellationTokens.cancel(cs1)

    @info "[test] Cancel during activation: waiting for first testrun"
    TestHelpers.timed_wait(testrun_task1, 120; label="cancel-activation-testrun1")

    # The controller reactor must still be running (no crash)
    @test !istaskdone(controller_task)
    @test controller_error[] === nothing

    # All items from the first run should be accounted for
    completed1 = filter(e -> e.event in (:passed, :failed, :errored, :skipped), events)
    @test length(completed1) == length(discovered.items)

    # --- Second run: verify controller is still functional ---
    empty!(events)
    testrun_id2 = string(UUIDs.uuid4())
    work_units2 = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in discovered.items]

    testrun_task2 = @async try
        execute_testrun(
            controller,
            testrun_id2,
            [test_env],
            discovered.items,
            work_units2,
            discovered.setups,
            1,
            nothing  # no cancellation token — let it run to completion
        )
    catch err
        @error "Test run 2 error" exception=(err, catch_backtrace())
    end

    @info "[test] Cancel during activation: waiting for second testrun"
    TestHelpers.timed_wait(testrun_task2, 300; label="cancel-activation-testrun2")

    @info "[test] Cancel during activation: shutting down"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 120; label="cancel-activation-controller")

    # Second run should complete normally — every item passed or had a definitive result
    completed2 = filter(e -> e.event in (:passed, :failed, :errored, :skipped), events)
    @test length(completed2) == length(discovered.items)

    # Controller should have shut down cleanly, not crashed
    @test controller_error[] === nothing
end

@testitem "Cancel multi-process test run after item completes (steal race)" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail,
        execute_testrun, shutdown, CancellationTokens, ControllerCallbacks
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    events = NamedTuple[]
    events_lock = ReentrantLock()
    first_item_done = Ref(false)
    first_item_cond = Threads.Condition()
    controller_error = Ref{Any}(nothing)

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:started, testitem_id=item_id)); end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> begin
            lock(events_lock) do; push!(events, (event=:passed, testitem_id=item_id)); end
            lock(first_item_cond) do
                first_item_done[] = true
                notify(first_item_cond)
            end
        end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> begin
            lock(events_lock) do; push!(events, (event=:failed, testitem_id=item_id)); end
            lock(first_item_cond) do
                first_item_done[] = true
                notify(first_item_cond)
            end
        end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> begin
            lock(events_lock) do; push!(events, (event=:errored, testitem_id=item_id)); end
            lock(first_item_cond) do
                first_item_done[] = true
                notify(first_item_cond)
            end
        end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do; push!(events, (event=:skipped, testitem_id=item_id)); end,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    testrun_id = string(UUIDs.uuid4())

    cs = CancellationTokens.CancellationTokenSource()
    token = CancellationTokens.get_token(cs)

    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in discovered.items]

    controller_task = @async try
        run(controller)
    catch err
        controller_error[] = err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    testrun_task = @async try
        execute_testrun(
            controller,
            testrun_id,
            [test_env],
            discovered.items,
            work_units,
            discovered.setups,
            3,  # multiple procs so stealing can be attempted
            token
        )
    catch err
        @error "Test run error" exception=(err, catch_backtrace())
    end

    # Wait for at least one test item to complete before cancelling
    lock(first_item_cond) do
        while !first_item_done[]
            wait(first_item_cond)
        end
    end

    @info "[test] Cancel multi-process steal race: cancelling after first item completed"
    CancellationTokens.cancel(cs)

    @info "[test] Cancel multi-process steal race: waiting for testrun"
    TestHelpers.timed_wait(testrun_task, 120; label="cancel-steal-race-testrun")

    @info "[test] Cancel multi-process steal race: shutting down"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 120; label="cancel-steal-race-controller")

    # Controller must not have crashed
    @test !istaskfailed(controller_task)
    @test controller_error[] === nothing

    # All items should be accounted for
    completed = filter(e -> e.event in (:passed, :failed, :errored, :skipped), events)
    @test length(completed) == length(discovered.items)
end
