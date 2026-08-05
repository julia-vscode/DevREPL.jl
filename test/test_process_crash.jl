@testitem "Controlled crash via exit()" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown, ControllerCallbacks
    import UUIDs
    @info "[test] Controlled crash via exit(): starting"

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Get the exit-crashing item and a passing item
    crash_items = filter(i -> i.label == "exit crash", discovered.items)
    passing_items = filter(i -> i.label == "add works", discovered.items)
    @test length(crash_items) == 1
    @test length(passing_items) == 1

    all_items = vcat(crash_items, passing_items)

    events = NamedTuple[]
    events_lock = ReentrantLock()
    process_events = NamedTuple[]
    process_events_lock = ReentrantLock()

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do
            push!(events, (event=:started, testitem_id=item_id))
        end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do
            push!(events, (event=:passed, testitem_id=item_id))
        end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:failed, testitem_id=item_id, messages=messages))
        end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:errored, testitem_id=item_id, messages=messages))
        end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do
            push!(events, (event=:skipped, testitem_id=item_id))
        end,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
        on_process_created = (id, test_env_id) -> lock(process_events_lock) do
            push!(process_events, (event=:process_created, id=id))
        end,
        on_process_terminated = id -> lock(process_events_lock) do
            push!(process_events, (event=:process_terminated, id=id))
        end,
        on_process_status_changed = (id, status) -> nothing,
        on_process_output = (id, output) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    testrun_id = string(UUIDs.uuid4())
    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in all_items]

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    @info "[test] Controlled crash via exit(): executing testrun"
    testrun_task = @async try
        execute_testrun(controller, testrun_id, [test_env], all_items, work_units, discovered.setups, 1, nothing)
    catch err
        @error "Test run error" exception=(err, catch_backtrace())
    end

    # The testrun should complete naturally: crash item errored, passing item redistributed and passed.
    TestHelpers.timed_wait(testrun_task, 120; label="exit-crash-testrun")

    @info "[test] Controlled crash via exit(): shutting down"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 120; label="exit-crash-controller")

    @info "[test] Controlled crash via exit(): verifying results"

    # The crashing item should be errored with a crash message
    crash_id = crash_items[1].id
    crash_errored = lock(events_lock) do
        filter(e -> e.testitem_id == crash_id && e.event == :errored, events)
    end
    @test length(crash_errored) == 1
    @test any(m -> occursin("crashed", m.message), crash_errored[1].messages)

    # The passing item should have passed (redistributed to a replacement process)
    pass_id = passing_items[1].id
    pass_passed = lock(events_lock) do
        filter(e -> e.testitem_id == pass_id && e.event == :passed, events)
    end
    @test length(pass_passed) == 1

    # A replacement process may or may not be created depending on item execution order.
    # If the crash item ran first, the passing item needs a replacement process.
    # If the passing item ran first, it already completed and no replacement is needed.
    created = lock(process_events_lock) do
        filter(e -> e.event == :process_created, process_events)
    end
    @test length(created) >= 1

    # At least one process should have been terminated (the crashed one)
    terminated = lock(process_events_lock) do
        filter(e -> e.event == :process_terminated, process_events)
    end
    @test length(terminated) >= 1
end

@testitem "Hard crash via ccall abort" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown, ControllerCallbacks
    import UUIDs
    @info "[test] Hard crash via ccall abort: starting"

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Get the abort-crashing item and a passing item
    crash_items = filter(i -> i.label == "abort crash", discovered.items)
    passing_items = filter(i -> i.label == "greet works", discovered.items)
    @test length(crash_items) == 1
    @test length(passing_items) == 1

    all_items = vcat(crash_items, passing_items)

    events = NamedTuple[]
    events_lock = ReentrantLock()
    process_events = NamedTuple[]
    process_events_lock = ReentrantLock()

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do
            push!(events, (event=:started, testitem_id=item_id))
        end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do
            push!(events, (event=:passed, testitem_id=item_id))
        end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:failed, testitem_id=item_id, messages=messages))
        end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:errored, testitem_id=item_id, messages=messages))
        end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do
            push!(events, (event=:skipped, testitem_id=item_id))
        end,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
        on_process_created = (id, test_env_id) -> lock(process_events_lock) do
            push!(process_events, (event=:process_created, id=id))
        end,
        on_process_terminated = id -> lock(process_events_lock) do
            push!(process_events, (event=:process_terminated, id=id))
        end,
        on_process_status_changed = (id, status) -> nothing,
        on_process_output = (id, output) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    testrun_id = string(UUIDs.uuid4())
    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in all_items]

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    @info "[test] Hard crash via ccall abort: executing testrun"
    testrun_task = @async try
        execute_testrun(controller, testrun_id, [test_env], all_items, work_units, discovered.setups, 1, nothing)
    catch err
        @error "Test run error" exception=(err, catch_backtrace())
    end

    # On Windows, ccall(:abort) may trigger Windows Error Reporting which keeps the
    # process alive, preventing crash detection via pipe IO error.  Poll for the crash
    # item to reach a terminal state; if undetected after 60s, force shutdown.
    crash_id = crash_items[1].id
    pass_id = passing_items[1].id
    deadline = time() + 60
    crash_detected_early = Ref(false)
    while time() < deadline
        done = lock(events_lock) do
            any(e -> e.testitem_id == crash_id && e.event in (:errored, :skipped), events)
        end
        if done
            crash_detected_early[] = true
            break
        end
        sleep(1.0)
    end

    @info "[test] Hard crash via ccall abort: shutting down (crash_detected_early=$(crash_detected_early[]))"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 120; label="abort-crash-controller")
    if !istaskdone(testrun_task)
        TestHelpers.timed_wait(testrun_task, 30; label="abort-crash-testrun")
    end

    @info "[test] Hard crash via ccall abort: verifying results"

    # The crashing item should reach a terminal state (errored by crash handler, or skipped by shutdown)
    crash_terminal = lock(events_lock) do
        filter(e -> e.testitem_id == crash_id && e.event in (:errored, :skipped), events)
    end
    @test length(crash_terminal) >= 1

    # The passing item should have reached a terminal state
    pass_terminal = lock(events_lock) do
        filter(e -> e.testitem_id == pass_id && e.event in (:passed, :errored, :skipped), events)
    end
    @test length(pass_terminal) >= 1

    # At least one process should have been terminated
    terminated = lock(process_events_lock) do
        filter(e -> e.event == :process_terminated, process_events)
    end
    @test length(terminated) >= 1
end

@testitem "Single crash item is immediately errored" setup=[TestHelpers] begin
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown, ControllerCallbacks
    import UUIDs
    @info "[test] Single crash item is immediately errored: starting"

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Run ONLY the crashing item — it crashes, gets immediately errored, testrun completes.
    crash_items = filter(i -> i.label == "exit crash", discovered.items)
    @test length(crash_items) == 1

    events = NamedTuple[]
    events_lock = ReentrantLock()
    process_events = NamedTuple[]
    process_events_lock = ReentrantLock()

    callbacks = ControllerCallbacks(
        on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do
            push!(events, (event=:started, testitem_id=item_id))
        end,
        on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do
            push!(events, (event=:passed, testitem_id=item_id))
        end,
        on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:failed, testitem_id=item_id, messages=messages))
        end,
        on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
            push!(events, (event=:errored, testitem_id=item_id, messages=messages))
        end,
        on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do
            push!(events, (event=:skipped, testitem_id=item_id))
        end,
        on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
        on_attach_debugger = (run_id, pipe_name) -> nothing,
        on_process_created = (id, test_env_id) -> lock(process_events_lock) do
            push!(process_events, (event=:process_created, id=id))
        end,
        on_process_terminated = id -> lock(process_events_lock) do
            push!(process_events, (event=:process_terminated, id=id))
        end,
        on_process_status_changed = (id, status) -> nothing,
        on_process_output = (id, output) -> nothing,
    )

    controller = TestItemController(callbacks; log_level=:Debug)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    testrun_id = string(UUIDs.uuid4())
    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in crash_items]

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    @info "[test] Single crash item: executing testrun"
    testrun_task = @async try
        execute_testrun(controller, testrun_id, [test_env], crash_items, work_units, discovered.setups, 1, nothing)
    catch err
        @error "Test run error" exception=(err, catch_backtrace())
    end

    # Testrun completes naturally — the crash item is immediately errored, no other items remain.
    TestHelpers.timed_wait(testrun_task, 120; label="single-crash-testrun")

    @info "[test] Single crash item: shutting down"
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, 120; label="single-crash-controller")

    @info "[test] Single crash item: verifying results"

    # The crash item should be errored with a crash message
    crash_id = crash_items[1].id
    crash_errored = lock(events_lock) do
        filter(e -> e.testitem_id == crash_id && e.event == :errored, events)
    end
    @test length(crash_errored) == 1
    @test any(m -> occursin("crashed", m.message), crash_errored[1].messages)

    # Only 1 process should have been created (no replacement needed)
    created = lock(process_events_lock) do
        filter(e -> e.event == :process_created, process_events)
    end
    @test length(created) == 1

    # The crashed process should have been terminated
    terminated = lock(process_events_lock) do
        filter(e -> e.event == :process_terminated, process_events)
    end
    @test length(terminated) == 1
end
