# Precompile workload: run the controller paths every consumer (juliati, the
# VS Code extension, JuliaMCP) pays for on startup — the reactor loop and its
# message handlers, the execute_testrun entry path, result serialization and
# the JSONRPC endpoint machinery — without ever spawning child processes.

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    @compile_workload begin
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            noop_callbacks = ControllerCallbacks(
                on_testitem_started = (testrun_id, testitem_id, test_env_id) -> nothing,
                on_testitem_passed = (testrun_id, testitem_id, test_env_id, duration) -> nothing,
                on_testitem_failed = (testrun_id, testitem_id, test_env_id, messages, duration) -> nothing,
                on_testitem_errored = (testrun_id, testitem_id, test_env_id, messages, duration) -> nothing,
                on_testitem_skipped = (testrun_id, testitem_id, test_env_id) -> nothing,
                on_append_output = (testrun_id, testitem_id, test_env_id, output) -> nothing,
                on_attach_debugger = (testrun_id, debug_pipename) -> nothing,
                on_process_created = (id, test_env_id) -> nothing,
                on_process_terminated = id -> nothing,
                on_process_status_changed = (id, status) -> nothing,
                on_process_output = (id, output) -> nothing,
            )
            controller = TestItemController(noop_callbacks)
            reactor_task = @async run(controller)

            # Feed the reactor one message of every kind that is safe without a
            # live process or test run: every handler ignores unknown ids.
            put!(controller.reactor_channel, TestProcessStatusChangedMsg("no-such-process", "Launching"))
            put!(controller.reactor_channel, TestProcessOutputMsg("no-such-process", "output"))
            put!(controller.reactor_channel, TerminateTestProcessMsg("no-such-process"))
            put!(controller.reactor_channel, TestProcessTerminatedMsg("no-such-process"))
            put!(controller.reactor_channel, TestRunCancelledMsg("no-such-run"))
            put!(controller.reactor_channel, TestItemStartedMsg("no-such-run", "p", "i"))
            put!(controller.reactor_channel, TestItemPassedMsg("no-such-run", "p", "i", 1.0, nothing))
            put!(controller.reactor_channel, TestItemFailedMsg("no-such-run", "p", "i", [], 1.0))
            put!(controller.reactor_channel, TestItemErroredMsg("no-such-run", "p", "i", [], nothing))
            put!(controller.reactor_channel, TestItemSkippedStolenMsg("no-such-run", "p", "i"))
            put!(controller.reactor_channel, AppendOutputMsg("no-such-run", "p", nothing, "out"))
            put!(controller.reactor_channel, TestItemTimeoutMsg("no-such-run", "p", "i"))

            # execute_testrun entry path: an empty run returns before any
            # process would be spawned.
            execute_testrun(
                controller,
                "precompile-workload",
                TestEnvironment[],
                TestItemDetail[],
                TestRunItem[],
                TestSetupDetail[],
                1,
                nothing,
            )

            shutdown(controller)
            wait_for_shutdown(controller, reactor_task)
        end

        # URI helpers, hot on every discovery/reporting path.
        example_path = Sys.iswindows() ? "C:\\some\\dir\\file.jl" : "/some/dir/file.jl"
        uri2filepath(filepath2uri(example_path))

        # Result serialization round-trip.
        sample_result = Results.TestrunResult(
            [Results.TestrunResultDefinitionError("msg", "file:///t.jl", 1, 1)],
            [Results.TestrunResultTestitem("item", "file:///t.jl", [
                Results.TestrunResultTestitemProfile("Default", :passed, 1.5, nothing, nothing),
                Results.TestrunResultTestitemProfile("Other", :failed, 2.5,
                    [Results.TestrunResultMessage("failed", "1", "2", "file:///t.jl", 1, 1,
                        [Results.TestrunResultStackFrame("f", "file:///t.jl", 1, 1)])],
                    "captured output"),
            ])],
            Dict{String,String}("process-1" => "output"),
        )
        results_io = IOBuffer()
        Results.write_json(results_io, sample_result)
        Results.read_json(IOBuffer(take!(results_io)))

        # Vendored JSON on a protocol-shaped payload.
        JSON.parse(JSON.json(Dict(
            "id" => 1,
            "method" => "started",
            "params" => Dict("testitem_id" => "abc", "duration" => 1.5, "messages" => []),
        )))

        # In-process JSONRPC endpoint pair over a named pipe: compiles the
        # framing, serialization, request/response and notification machinery
        # the controller uses to talk to its test processes. A real socket pair
        # (not BufferStreams) matters: JSONRPCEndpoint is parametric in the IO
        # type, and the runtime endpoints are PipeEndpoint-typed.
        pipe_name = JSONRPC.generate_pipe_name()
        listener = Sockets.listen(pipe_name)
        accept_task = @async Sockets.accept(listener)
        stream_b = Sockets.connect(pipe_name)
        stream_a = fetch(accept_task)
        server = JSONRPC.JSONRPCEndpoint(stream_a, stream_a)
        client = JSONRPC.JSONRPCEndpoint(stream_b, stream_b)
        # Params must be structured (Dict/NamedTuple/protocol struct); a bare
        # string is not valid JSON-RPC params for this implementation.
        echo_request = JSONRPC.RequestType("echo", @NamedTuple{value::String}, String)
        note_notification = JSONRPC.NotificationType("note", @NamedTuple{value::String})
        dispatcher = JSONRPC.MsgDispatcher()
        dispatcher[echo_request] = (conn, params, token) -> params.value
        dispatcher[note_notification] = (conn, params) -> nothing
        dispatcher[TestItemServerProtocol.testserver_activate_env_request_type] =
            (conn, params, token) -> TestItemServerProtocol.ActivateEnvResult(status = "success", error = missing)
        JSONRPC.start(server)
        JSONRPC.start(client)
        server_task = @async try
            for msg in server
                JSONRPC.dispatch_msg(server, dispatcher, msg)
            end
        catch
        end
        JSONRPC.send(client, note_notification, (value = "hello",))
        JSONRPC.send(client, echo_request, (value = "hello",))
        # The exact request/param types the controller sends when it activates
        # a test process's environment.
        JSONRPC.send(client, TestItemServerProtocol.testserver_activate_env_request_type,
            TestItemServerProtocol.ActivateEnvParams(
                projectUri = missing,
                packageUri = "file:///precompile-workload",
                packageName = "PrecompileWorkload",
            ))
        # Close the sockets before the endpoints so the read tasks unblock
        # (close(endpoint) waits on its read task).
        close(stream_a)
        close(stream_b)
        try close(client) catch end
        try close(server) catch end
        try wait(server_task) catch end
        close(listener)
    end
end
