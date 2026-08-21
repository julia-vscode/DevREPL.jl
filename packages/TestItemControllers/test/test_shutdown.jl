@testmodule ShutdownHelpers begin
    using TestItemControllers: ControllerCallbacks

    # Callbacks that record only what the shutdown tests look at.
    function recording_callbacks(events, events_lock)
        ControllerCallbacks(
            on_testitem_started = (run_id, item_id, test_env_id) -> lock(events_lock) do
                push!(events, (event=:started, testitem_id=item_id))
            end,
            on_testitem_passed = (run_id, item_id, test_env_id, duration) -> lock(events_lock) do
                push!(events, (event=:passed, testitem_id=item_id))
            end,
            on_testitem_failed = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
                push!(events, (event=:failed, testitem_id=item_id))
            end,
            on_testitem_errored = (run_id, item_id, test_env_id, messages, duration) -> lock(events_lock) do
                push!(events, (event=:errored, testitem_id=item_id))
            end,
            on_testitem_skipped = (run_id, item_id, test_env_id) -> lock(events_lock) do
                push!(events, (event=:skipped, testitem_id=item_id))
            end,
            on_append_output = (run_id, item_id, test_env_id, output) -> nothing,
            on_attach_debugger = (run_id, pipe_name) -> nothing,
        )
    end

    # Poll until `pred()` holds or `timeout` seconds have passed.
    function wait_until(pred; timeout=120, interval=0.2)
        deadline = time() + timeout
        while time() < deadline
            pred() && return true
            sleep(interval)
        end
        return pred()
    end

    # Every OS process the controller has launched. Grabbed *before* shutdown, because the
    # controller forgets a process once it believes it terminated — which is precisely the
    # bookkeeping these tests need to see through.
    child_processes(controller) = Base.Process[ps.jl_process for ps in values(controller.test_processes) if ps.jl_process !== nothing]
end

@testitem "Shutdown force-kills a test process that ignores SIGTERM" setup=[TestHelpers, ShutdownHelpers] begin
    using TestItemControllers: TestItemController, TestRunItem, execute_testrun, shutdown
    import UUIDs

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "HangingPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    items = filter(i -> i.label == "ignores sigterm and spins", discovered.items)
    @test length(items) == 1

    events = NamedTuple[]
    events_lock = ReentrantLock()
    callbacks = ShutdownHelpers.recording_callbacks(events, events_lock)

    # A long grace period: if the controller only ever came back via the shutdown deadline
    # this test would take that long, and the elapsed-time assertion below would fail.
    grace = 90.0
    controller = TestItemController(callbacks; log_level=:Debug, shutdown_grace_seconds=grace)
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    work_units = [TestRunItem(item.id, test_env.id, nothing, :Debug) for item in items]

    controller_task = @async try
        run(controller)
    catch err
        @error "Controller error" exception=(err, catch_backtrace())
    end

    testrun_task = @async try
        execute_testrun(controller, string(UUIDs.uuid4()), [test_env], items, work_units, discovered.setups, 1, nothing)
    catch err
        @error "Test run error" exception=(err, catch_backtrace())
    end

    # Wait until the item is actually running inside the child, then give it a moment to
    # install its SIGTERM handler and start spinning.
    @test ShutdownHelpers.wait_until(; timeout=300) do
        lock(events_lock) do
            any(e -> e.event == :started, events)
        end
    end
    sleep(3)

    procs = ShutdownHelpers.child_processes(controller)
    @test length(procs) == 1
    @test all(process_running, procs)

    t0 = time()
    shutdown(controller)
    TestHelpers.timed_wait(controller_task, grace + 60; label="shutdown-hung-controller")
    elapsed = time() - t0
    TestHelpers.timed_wait(testrun_task, 60; label="shutdown-hung-testrun")

    # The child must be gone by the time the controller reports it stopped ...
    @test all(p -> !process_running(p), procs)
    # ... and it must have been brought down by escalation, not by the last-resort deadline.
    @test elapsed < grace
    @info "[test] Shutdown force-kills a hung process: controller stopped after $(round(elapsed, digits=1))s"
end

@testitem "Closing the client connection shuts down controller and test processes" setup=[TestHelpers, JSONRPCHelpers, ShutdownHelpers] begin
    using Sockets
    using TestItemControllers: JSONRPCTestItemController, JSONRPC, TestItemControllerProtocol
    import UUIDs

    server_sock, client_sock = JSONRPCHelpers.get_connected_sockets()
    jr_controller = JSONRPCTestItemController(server_sock, server_sock)

    controller_task = @async try
        run(jr_controller)
    catch err
        @error "JR controller error" exception=(err, catch_backtrace())
    end

    client_endpoint = JSONRPC.JSONRPCEndpoint(client_sock, client_sock)
    JSONRPC.start(client_endpoint)
    notifications, notif_lock, stop_collector, collector_task = JSONRPCHelpers.collect_notifications(client_endpoint)

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    slow_items = filter(i -> i.label == "slow test", discovered.items)
    @test length(slow_items) == 1

    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    params = TestHelpers.build_create_testrun_params(string(UUIDs.uuid4()), test_env, slow_items, discovered.setups)

    # Fire the request without waiting for the response: it only completes when the run does,
    # and the run is going to be cut short.
    request_task = @async try
        JSONRPC.send(client_endpoint, TestItemControllerProtocol.create_testrun_request_type, params)
    catch err
        nothing
    end

    @test ShutdownHelpers.wait_until(; timeout=300) do
        lock(notif_lock) do
            any(n -> n.method == "testItemStarted", notifications)
        end
    end

    procs = ShutdownHelpers.child_processes(jr_controller.controller)
    @test length(procs) == 1
    @test all(process_running, procs)

    # The client goes away without saying goodbye — VS Code exiting, or crashing.
    stop_collector()
    close(client_sock)

    TestHelpers.timed_wait(controller_task, 120; label="controller after client hangup")
    @test all(p -> !process_running(p), procs)

    close(server_sock)
end

@testitem "shutdown notification terminates test processes" setup=[TestHelpers, JSONRPCHelpers, ShutdownHelpers] begin
    using Sockets
    using TestItemControllers: JSONRPCTestItemController, JSONRPC, TestItemControllerProtocol
    import UUIDs

    server_sock, client_sock = JSONRPCHelpers.get_connected_sockets()
    jr_controller = JSONRPCTestItemController(server_sock, server_sock)

    controller_task = @async try
        run(jr_controller)
    catch err
        @error "JR controller error" exception=(err, catch_backtrace())
    end

    client_endpoint = JSONRPC.JSONRPCEndpoint(client_sock, client_sock)
    JSONRPC.start(client_endpoint)
    notifications, notif_lock, stop_collector, collector_task = JSONRPCHelpers.collect_notifications(client_endpoint)

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    slow_items = filter(i -> i.label == "slow test", discovered.items)
    @test length(slow_items) == 1

    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)
    params = TestHelpers.build_create_testrun_params(string(UUIDs.uuid4()), test_env, slow_items, discovered.setups)

    request_task = @async try
        JSONRPC.send(client_endpoint, TestItemControllerProtocol.create_testrun_request_type, params)
    catch err
        nothing
    end

    @test ShutdownHelpers.wait_until(; timeout=300) do
        lock(notif_lock) do
            any(n -> n.method == "testItemStarted", notifications)
        end
    end

    procs = ShutdownHelpers.child_processes(jr_controller.controller)
    @test length(procs) == 1
    @test all(process_running, procs)

    JSONRPC.send(client_endpoint, TestItemControllerProtocol.shutdown_notification_type, nothing)

    TestHelpers.timed_wait(controller_task, 120; label="controller after shutdown notification")
    @test all(p -> !process_running(p), procs)

    # The client was still listening, so it heard about the termination.
    @test ShutdownHelpers.wait_until(; timeout=10) do
        lock(notif_lock) do
            any(n -> n.method == "testProcessTerminated", notifications)
        end
    end

    stop_collector()
    close(client_sock)
    close(server_sock)
end
