@testmodule JSONRPCHelpers begin
    using Sockets
    using TestItemControllers: JSONRPC, JSONRPCTestItemController, TestItemControllerProtocol, shutdown

    """
    Create a connected pair of sockets via named pipes, suitable for
    bidirectional JSONRPC communication in tests.
    """
    function get_connected_sockets()
        socket_name = JSONRPC.generate_pipe_name()
        server_is_up = Channel{Bool}(1)
        socket1_channel = Channel{Any}(1)

        @async try
            server = listen(socket_name)
            put!(server_is_up, true)
            sock = accept(server)
            put!(socket1_channel, sock)
        catch err
            Base.display_error(err, catch_backtrace())
        end

        wait(server_is_up)
        socket2 = connect(socket_name)
        socket1 = take!(socket1_channel)

        return socket1, socket2
    end

    """
    Collect JSONRPC notifications from a client endpoint asynchronously.
    Returns (notifications::Vector, stop::Function).
    Call `stop()` to end collection.
    """
    function collect_notifications(client_endpoint)
        notifications = NamedTuple[]
        lock = ReentrantLock()
        running = Ref(true)

        task = @async try
            while running[]
                msg = JSONRPC.get_next_message(client_endpoint)
                if msg.id === nothing  # notification
                    Base.@lock lock push!(notifications, (method=msg.method, params=msg.params))
                end
            end
        catch err
            # Endpoint closed or cancelled — expected during shutdown
            if !(err isa InvalidStateException || err isa EOFError || err isa Base.IOError)
                @error "Notification collector error" exception=(err, catch_backtrace())
            end
        end

        stop = () -> begin
            running[] = false
        end

        return notifications, lock, stop, task
    end
end

@testitem "JSONRPCTestItemController construction" setup=[JSONRPCHelpers] begin
    using Sockets
    using TestItemControllers: JSONRPCTestItemController, JSONRPC, shutdown

    server_sock, client_sock = JSONRPCHelpers.get_connected_sockets()

    try
        jr_controller = JSONRPCTestItemController(server_sock, server_sock)
        @test jr_controller isa JSONRPCTestItemController
        @test isdefined(jr_controller, :controller)
        @test isdefined(jr_controller, :endpoint)
    finally
        close(server_sock)
        close(client_sock)
    end
end

@testitem "createTestRun request with passing items" setup=[TestHelpers, JSONRPCHelpers] begin
    using Sockets
    using TestItemControllers: JSONRPCTestItemController, JSONRPC, TestItemControllerProtocol, shutdown
    @info "[test] createTestRun request with passing items: starting"

    server_sock, client_sock = JSONRPCHelpers.get_connected_sockets()

    jr_controller = JSONRPCTestItemController(server_sock, server_sock)

    # Start the controller (runs endpoint + reactor)
    controller_task = @async try
        run(jr_controller)
    catch err
        @error "JR controller error" exception=(err, catch_backtrace())
    end

    # Set up client endpoint
    client_endpoint = JSONRPC.JSONRPCEndpoint(client_sock, client_sock)
    JSONRPC.start(client_endpoint)

    # Collect notifications from the server
    notifications, notif_lock, stop_collector, collector_task = JSONRPCHelpers.collect_notifications(client_endpoint)

    import UUIDs

    # Discover test items
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)
    passing_items = filter(i -> i.label in ("add works", "greet works"), discovered.items)
    @test length(passing_items) >= 1

    # Build createTestRun params
    testrun_id = string(UUIDs.uuid4())

    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)

    params = TestItemControllerProtocol.CreateTestRunParams(
        testRunId = testrun_id,
        testEnvironments = [TestItemControllerProtocol.TestEnvironment(
            id = test_env.id,
            juliaCmd = test_env.julia_cmd,
            juliaArgs = test_env.julia_args,
            juliaNumThreads = something(test_env.julia_num_threads, missing),
            juliaEnv = test_env.julia_env,
            mode = test_env.mode,
            packageName = something(discovered.package_name, ""),
            packageUri = something(discovered.package_uri, ""),
            projectUri = (discovered.project_uri === nothing ? missing : discovered.project_uri),
            envContentHash = (discovered.env_content_hash === nothing ? missing : discovered.env_content_hash),
        )],
        testItems = [TestItemControllerProtocol.TestItemDetail(
            id = item.id,
            uri = item.uri,
            label = item.label,
            packageName = item.package_name,
            packageUri = item.package_uri,
            useDefaultUsings = item.option_default_imports,
            testSetups = item.test_setups,
            line = item.line,
            column = item.column,
            code = item.code,
            codeLine = item.code_line,
            codeColumn = item.code_column,
        ) for item in passing_items],
        workUnits = [TestItemControllerProtocol.TestRunItem(
            testitemId = item.id,
            testEnvId = test_env.id,
            timeout = missing,
            logLevel = "Debug",
        ) for item in passing_items],
        testSetups = [TestItemControllerProtocol.TestSetupDetail(
            packageUri = s.package_uri,
            name = s.name,
            kind = s.kind,
            uri = s.uri,
            line = s.line,
            column = s.column,
            code = s.code,
        ) for s in discovered.setups],
        maxProcessCount = 1,
        coverageRootUris = missing,
    )

    # Send the createTestRun request
    @info "[test] createTestRun with passing items: sending request"
    response = JSONRPC.send(client_endpoint, TestItemControllerProtocol.create_testrun_request_type, params)

    @test response.status == "success"

    # Give a moment for remaining notifications to arrive
    sleep(1.0)

    # Shut down
    @info "[test] createTestRun with passing items: shutting down"
    stop_collector()
    shutdown(jr_controller.controller)
    TestHelpers.timed_wait(controller_task, 120; label="jsonrpc-passing-controller")
    @info "[test] createTestRun with passing items: verifying"

    # Analyze notifications
    started = lock(notif_lock) do
        filter(n -> n.method == "testItemStarted", notifications)
    end
    passed = lock(notif_lock) do
        filter(n -> n.method == "testItemPassed", notifications)
    end
    failed = lock(notif_lock) do
        filter(n -> n.method == "testItemFailed", notifications)
    end
    errored = lock(notif_lock) do
        filter(n -> n.method == "testItemErrored", notifications)
    end
    process_created = lock(notif_lock) do
        filter(n -> n.method == "testProcessCreated", notifications)
    end

    @test length(started) == length(passing_items)
    @test length(passed) == length(passing_items)
    @test length(failed) == 0
    @test length(errored) == 0
    @test length(process_created) >= 1

    # Verify testRunId in notifications
    for n in started
        @test n.params["testRunId"] == testrun_id
    end
    for n in passed
        @test n.params["testRunId"] == testrun_id
        @test haskey(n.params, "duration")
    end

    close(client_sock)
    close(server_sock)
end

@testitem "createTestRun with failing and erroring items" setup=[TestHelpers, JSONRPCHelpers] begin
    using Sockets
    using TestItemControllers: JSONRPCTestItemController, JSONRPC, TestItemControllerProtocol, shutdown
    import UUIDs
    @info "[test] createTestRun with failing and erroring items: starting"

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

    # failing + erroring items
    target_items = filter(i -> i.label in ("failing test", "erroring test"), discovered.items)
    @test length(target_items) == 2

    testrun_id = string(UUIDs.uuid4())
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)

    params = TestItemControllerProtocol.CreateTestRunParams(
        testRunId = testrun_id,
        testEnvironments = [TestItemControllerProtocol.TestEnvironment(
            id = test_env.id, juliaCmd = test_env.julia_cmd,
            juliaArgs = test_env.julia_args, juliaNumThreads = something(test_env.julia_num_threads, missing),
            juliaEnv = test_env.julia_env, mode = test_env.mode,
            packageName = something(discovered.package_name, ""),
            packageUri = something(discovered.package_uri, ""),
            projectUri = (discovered.project_uri === nothing ? missing : discovered.project_uri),
            envContentHash = (discovered.env_content_hash === nothing ? missing : discovered.env_content_hash),
        )],
        testItems = [TestItemControllerProtocol.TestItemDetail(
            id = item.id, uri = item.uri, label = item.label,
            packageName = item.package_name, packageUri = item.package_uri,
            useDefaultUsings = item.option_default_imports, testSetups = item.test_setups,
            line = item.line, column = item.column, code = item.code,
            codeLine = item.code_line, codeColumn = item.code_column,
        ) for item in target_items],
        workUnits = [TestItemControllerProtocol.TestRunItem(
            testitemId = item.id, testEnvId = test_env.id,
            timeout = missing, logLevel = "Debug",
        ) for item in target_items],
        testSetups = [TestItemControllerProtocol.TestSetupDetail(
            packageUri = s.package_uri, name = s.name, kind = s.kind,
            uri = s.uri, line = s.line, column = s.column, code = s.code,
        ) for s in discovered.setups],
        maxProcessCount = 1,
        coverageRootUris = missing,
    )

    response = JSONRPC.send(client_endpoint, TestItemControllerProtocol.create_testrun_request_type, params)
    @test response.status == "success"

    sleep(1.0)

    @info "[test] createTestRun with failing items: shutting down"
    stop_collector()
    shutdown(jr_controller.controller)
    TestHelpers.timed_wait(controller_task, 120; label="jsonrpc-failing-controller")

    failed = lock(notif_lock) do
        filter(n -> n.method == "testItemFailed", notifications)
    end
    errored = lock(notif_lock) do
        filter(n -> n.method == "testItemErrored", notifications)
    end
    passed = lock(notif_lock) do
        filter(n -> n.method == "testItemPassed", notifications)
    end

    @test length(failed) + length(errored) == length(target_items)
    @test length(passed) == 0

    # Verify messages arrays are present
    for n in vcat(failed, errored)
        @test haskey(n.params, "messages")
        @test length(n.params["messages"]) >= 1
    end

    close(client_sock)
    close(server_sock)
end

@testitem "Process lifecycle notifications via JSONRPC" setup=[TestHelpers, JSONRPCHelpers] begin
    using Sockets
    using TestItemControllers: JSONRPCTestItemController, JSONRPC, TestItemControllerProtocol, shutdown
    import UUIDs
    @info "[test] Process lifecycle notifications via JSONRPC: starting"

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
    passing_items = filter(i -> i.label == "add works", discovered.items)

    testrun_id = string(UUIDs.uuid4())
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)

    params = TestItemControllerProtocol.CreateTestRunParams(
        testRunId = testrun_id,
        testEnvironments = [TestItemControllerProtocol.TestEnvironment(
            id = test_env.id, juliaCmd = test_env.julia_cmd,
            juliaArgs = test_env.julia_args, juliaNumThreads = something(test_env.julia_num_threads, missing),
            juliaEnv = test_env.julia_env, mode = test_env.mode,
            packageName = something(discovered.package_name, ""),
            packageUri = something(discovered.package_uri, ""),
            projectUri = (discovered.project_uri === nothing ? missing : discovered.project_uri),
            envContentHash = (discovered.env_content_hash === nothing ? missing : discovered.env_content_hash),
        )],
        testItems = [TestItemControllerProtocol.TestItemDetail(
            id = item.id, uri = item.uri, label = item.label,
            packageName = item.package_name, packageUri = item.package_uri,
            useDefaultUsings = item.option_default_imports, testSetups = item.test_setups,
            line = item.line, column = item.column, code = item.code,
            codeLine = item.code_line, codeColumn = item.code_column,
        ) for item in passing_items],
        workUnits = [TestItemControllerProtocol.TestRunItem(
            testitemId = item.id, testEnvId = test_env.id,
            timeout = missing, logLevel = "Debug",
        ) for item in passing_items],
        testSetups = [TestItemControllerProtocol.TestSetupDetail(
            packageUri = s.package_uri, name = s.name, kind = s.kind,
            uri = s.uri, line = s.line, column = s.column, code = s.code,
        ) for s in discovered.setups],
        maxProcessCount = 1,
        coverageRootUris = missing,
    )

    response = JSONRPC.send(client_endpoint, TestItemControllerProtocol.create_testrun_request_type, params)
    @test response.status == "success"

    sleep(1.0)

    @info "[test] Process lifecycle via JSONRPC: shutting down"
    shutdown(jr_controller.controller)
    TestHelpers.timed_wait(controller_task, 120; label="jsonrpc-lifecycle-controller")

    # Stop collecting notifications after shutdown completes, to capture testProcessTerminated
    sleep(1.0)
    stop_collector()

    process_created = lock(notif_lock) do
        filter(n -> n.method == "testProcessCreated", notifications)
    end
    status_changed = lock(notif_lock) do
        filter(n -> n.method == "testProcessStatusChanged", notifications)
    end
    process_terminated = lock(notif_lock) do
        filter(n -> n.method == "testProcessTerminated", notifications)
    end

    # At least one process was created
    @test length(process_created) >= 1

    # Process created notification should have expected fields
    pc = first(process_created)
    @test haskey(pc.params, "id")
    @test haskey(pc.params, "packageName")
    @test haskey(pc.params, "coverage")

    # Status changed notifications should occur
    @test length(status_changed) >= 1

    # After shutdown, process should be terminated
    @test length(process_terminated) >= 1

    close(client_sock)
    close(server_sock)
end

@testitem "appendOutput notifications via JSONRPC" setup=[TestHelpers, JSONRPCHelpers] begin
    using Sockets
    using TestItemControllers: JSONRPCTestItemController, JSONRPC, TestItemControllerProtocol, shutdown
    import UUIDs
    @info "[test] appendOutput notifications via JSONRPC: starting"

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

    # Use the "output test" item that prints things
    output_items = filter(i -> i.label == "output test", discovered.items)
    @test length(output_items) == 1

    testrun_id = string(UUIDs.uuid4())
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)

    params = TestItemControllerProtocol.CreateTestRunParams(
        testRunId = testrun_id,
        testEnvironments = [TestItemControllerProtocol.TestEnvironment(
            id = test_env.id, juliaCmd = test_env.julia_cmd,
            juliaArgs = test_env.julia_args, juliaNumThreads = something(test_env.julia_num_threads, missing),
            juliaEnv = test_env.julia_env, mode = test_env.mode,
            packageName = something(discovered.package_name, ""),
            packageUri = something(discovered.package_uri, ""),
            projectUri = (discovered.project_uri === nothing ? missing : discovered.project_uri),
            envContentHash = (discovered.env_content_hash === nothing ? missing : discovered.env_content_hash),
        )],
        testItems = [TestItemControllerProtocol.TestItemDetail(
            id = item.id, uri = item.uri, label = item.label,
            packageName = item.package_name, packageUri = item.package_uri,
            useDefaultUsings = item.option_default_imports, testSetups = item.test_setups,
            line = item.line, column = item.column, code = item.code,
            codeLine = item.code_line, codeColumn = item.code_column,
        ) for item in output_items],
        workUnits = [TestItemControllerProtocol.TestRunItem(
            testitemId = item.id, testEnvId = test_env.id,
            timeout = missing, logLevel = "Debug",
        ) for item in output_items],
        testSetups = [TestItemControllerProtocol.TestSetupDetail(
            packageUri = s.package_uri, name = s.name, kind = s.kind,
            uri = s.uri, line = s.line, column = s.column, code = s.code,
        ) for s in discovered.setups],
        maxProcessCount = 1,
        coverageRootUris = missing,
    )

    response = JSONRPC.send(client_endpoint, TestItemControllerProtocol.create_testrun_request_type, params)
    @test response.status == "success"

    sleep(1.0)

    @info "[test] appendOutput via JSONRPC: shutting down"
    stop_collector()
    shutdown(jr_controller.controller)
    TestHelpers.timed_wait(controller_task, 120; label="jsonrpc-output-controller")

    append_output = lock(notif_lock) do
        filter(n -> n.method == "appendOutput", notifications)
    end

    # Should have received output notifications
    @test length(append_output) >= 1

    # Combine all output text
    all_output = join([n.params["output"] for n in append_output], "")
    @test occursin("hello from output test", all_output)

    close(client_sock)
    close(server_sock)
end

@testitem "terminateTestProcess request via JSONRPC" setup=[TestHelpers, JSONRPCHelpers] begin
    using Sockets
    using TestItemControllers: JSONRPCTestItemController, JSONRPC, TestItemControllerProtocol, shutdown
    import UUIDs
    @info "[test] terminateTestProcess request via JSONRPC: starting"

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

    # Use a slow test so the process stays alive while we terminate it
    slow_items = filter(i -> i.label == "slow test", discovered.items)
    @test length(slow_items) == 1

    testrun_id = string(UUIDs.uuid4())
    test_env = TestHelpers.make_test_environment(; TestHelpers._env_kwargs(discovered)...)

    params = TestItemControllerProtocol.CreateTestRunParams(
        testRunId = testrun_id,
        testEnvironments = [TestItemControllerProtocol.TestEnvironment(
            id = test_env.id, juliaCmd = test_env.julia_cmd,
            juliaArgs = test_env.julia_args, juliaNumThreads = something(test_env.julia_num_threads, missing),
            juliaEnv = test_env.julia_env, mode = test_env.mode,
            packageName = something(discovered.package_name, ""),
            packageUri = something(discovered.package_uri, ""),
            projectUri = (discovered.project_uri === nothing ? missing : discovered.project_uri),
            envContentHash = (discovered.env_content_hash === nothing ? missing : discovered.env_content_hash),
        )],
        testItems = [TestItemControllerProtocol.TestItemDetail(
            id = item.id, uri = item.uri, label = item.label,
            packageName = item.package_name, packageUri = item.package_uri,
            useDefaultUsings = item.option_default_imports, testSetups = item.test_setups,
            line = item.line, column = item.column, code = item.code,
            codeLine = item.code_line, codeColumn = item.code_column,
        ) for item in slow_items],
        workUnits = [TestItemControllerProtocol.TestRunItem(
            testitemId = item.id, testEnvId = test_env.id,
            timeout = missing, logLevel = "Debug",
        ) for item in slow_items],
        testSetups = [TestItemControllerProtocol.TestSetupDetail(
            packageUri = s.package_uri, name = s.name, kind = s.kind,
            uri = s.uri, line = s.line, column = s.column, code = s.code,
        ) for s in discovered.setups],
        maxProcessCount = 1,
        coverageRootUris = missing,
    )

    # Send createTestRun (async since the slow test won't finish quickly)
    response_task = @async JSONRPC.send(client_endpoint, TestItemControllerProtocol.create_testrun_request_type, params)

    # Wait for the slow test item to actually start running before we terminate
    process_id = Ref{Union{Nothing,String}}(nothing)
    deadline = time() + 120
    while time() < deadline
        lock(notif_lock) do
            started = filter(n -> n.method == "testItemStarted", notifications)
            if !isempty(started)
                # Also grab the process id from the testProcessCreated notification
                created = filter(n -> n.method == "testProcessCreated", notifications)
                if !isempty(created)
                    process_id[] = first(created).params["id"]
                end
            end
        end
        process_id[] !== nothing && break
        sleep(0.5)
    end
    @test process_id[] !== nothing

    # Terminate the test process
    JSONRPC.send(
        client_endpoint,
        TestItemControllerProtocol.terminate_test_process_request_type,
        TestItemControllerProtocol.TerminateTestProcessParams(testProcessId=process_id[])
    )

    # Wait for the createTestRun to complete — should finish promptly after
    # process termination errors the remaining items (not redistribute them).
    @info "[test] terminateTestProcess: waiting for response"
    TestHelpers.timed_wait(response_task, 120; label="jsonrpc-terminate-response")
    response = fetch(response_task)
    @test response.status == "success"

    sleep(1.0)

    @info "[test] terminateTestProcess: shutting down"
    stop_collector()
    shutdown(jr_controller.controller)
    TestHelpers.timed_wait(controller_task, 120; label="jsonrpc-terminate-controller")

    terminated = lock(notif_lock) do
        filter(n -> n.method == "testProcessTerminated", notifications)
    end
    errored = lock(notif_lock) do
        filter(n -> n.method == "testItemErrored", notifications)
    end
    passed = lock(notif_lock) do
        filter(n -> n.method == "testItemPassed", notifications)
    end

    @test length(terminated) >= 1
    @test any(n -> n.params["id"] == process_id[], terminated)

    # The slow test item should have been errored, not redistributed
    @test length(errored) == length(slow_items)
    @test length(passed) == 0
    for n in errored
        @test haskey(n.params, "messages")
        @test length(n.params["messages"]) >= 1
    end

    close(client_sock)
    close(server_sock)
end
