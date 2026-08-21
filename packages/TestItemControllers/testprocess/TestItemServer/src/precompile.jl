# Executed workload: run the hottest per-item path (run_testitem with a passing
# and a failing test) for real during package-image generation, so the compiled
# code — including everything inference reaches transitively — is cached. A
# signature list cannot capture that. Every worker launch pays for whatever is
# missing here.
function _precompile_workload_()
    old_pwd = pwd()  # run_testitem cds into the test file's directory
    try
        mktempdir() do dir
            test_file = joinpath(dir, "test_file.jl")
            write(test_file, "# precompile workload\n")
            uri = filepath2uri(test_file)

            # In-memory endpoint: BufferStreams are unbounded, so the
            # notifications run_testitem sends need no reader.
            stream_a = Base.BufferStream()
            stream_b = Base.BufferStream()
            endpoint = JSONRPC.JSONRPCEndpoint(stream_a, stream_b)
            JSONRPC.start(endpoint)
            state = TestProcessState(endpoint)

            make_item(id, name, code) = TestItemServerProtocol.RunTestItem(
                id = id,
                uri = uri,
                name = name,
                packageName = "",
                packageUri = "file:///nonexistent",
                useDefaultUsings = true,
                testSetups = String[],
                line = 1,
                column = 1,
                code = code,
            )

            Logging.with_logger(Logging.NullLogger()) do
                redirect_stdout(devnull) do
                    redirect_stderr(devnull) do
                        for (item, expected_type) in (
                            (make_item("wl-1", "passing", "@test 1 == 1"), TestItemServerProtocol.PassedParams),
                            (make_item("wl-2", "failing", "@test 1 == 2"), TestItemServerProtocol.FailedParams),
                            (make_item("wl-3", "erroring", "error(\"boom\")"), TestItemServerProtocol.ErroredParams),
                        )
                            notification_type, notification_params =
                                run_testitem(endpoint, item, "Normal", nothing, state;
                                    testcode_module_parent=@__MODULE__)
                            # Send the result the same way runner_loop does.
                            JSONRPC.send(endpoint, notification_type, notification_params)
                            @assert notification_params isa expected_type
                        end
                    end
                end
            end

            # BufferStream reads are not cancellation-aware: close the streams
            # before the endpoint so its read task unblocks.
            JSONRPC.flush(endpoint)
            close(stream_a)
            close(stream_b)
            try close(endpoint) catch end

            # Leave the temp dir before mktempdir removes it: run_testitem cd'd
            # into it, and Windows cannot delete the current directory.
            cd(old_pwd)
        end

        # Leaf helpers with real inputs.
        withpath(() -> nothing, old_pwd)
        is_infrastructure_frame(@__FILE__)
        process_coverage_data(CoverageTools.FileCoverage[])
        parse_log_level(:info)
        try
            error("workload")
        catch err
            bt = catch_backtrace()
            format_error_message(err, bt)
            find_error_location(stacktrace(bt))
            backtrace_to_stackframes(bt)
        end
    catch err
        # A failed workload must never break the test server itself — fall back
        # to whatever the signature list below provides.
        @warn "TestItemServer precompile workload failed" exception = err
    finally
        cd(old_pwd)
    end
    return nothing
end

function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

    _precompile_workload_()

    # Signature-only directives for paths the workload cannot execute
    # (request handlers need a live protocol session; coverage needs
    # --code-coverage; the debug backend needs a debuggee).

    # Error formatting
    precompile(Tuple{typeof(parse_backtrace_string), String})

    # Coverage
    @static if VERSION >= v"1.11.0-rc2"
        precompile(Tuple{typeof(clear_coverage_data)})
        precompile(Tuple{typeof(collect_coverage_data!), Vector{CoverageTools.FileCoverage}, Vector{String}})
    end

    # Request handlers
    precompile(Tuple{typeof(revise_request), Nothing, TestProcessState, CancellationToken})
    precompile(Tuple{typeof(activate_env_request), TestItemServerProtocol.ActivateEnvParams, TestProcessState, CancellationToken})
    precompile(Tuple{typeof(configure_test_run_request), TestItemServerProtocol.ConfigureTestRunRequestParams, TestProcessState, CancellationToken})
    precompile(Tuple{typeof(run_testitems_batch_request), TestItemServerProtocol.RunTestItemsRequestParams, TestProcessState, CancellationToken})
    precompile(Tuple{typeof(steal_testitems_request), TestItemServerProtocol.StealTestItemsRequestParams, TestProcessState, CancellationToken})
    precompile(Tuple{typeof(shutdown_request), Nothing, TestProcessState, CancellationToken})

    # Runner loop
    precompile(Tuple{typeof(runner_loop), TestProcessState})

    # Test execution (hottest path, two variants for coverage_root_uris)
    precompile(Tuple{typeof(run_testitem), JSONRPC.JSONRPCEndpoint, TestItemServerProtocol.RunTestItem, String, Nothing, TestProcessState})
    precompile(Tuple{typeof(run_testitem), JSONRPC.JSONRPCEndpoint, TestItemServerProtocol.RunTestItem, String, Vector{String}, TestProcessState})

    # JSONRPC send for notification types used in the server
    precompile(Tuple{typeof(JSONRPC.send), JSONRPC.JSONRPCEndpoint, JSONRPC.NotificationType{TestItemServerProtocol.StartedParams}, TestItemServerProtocol.StartedParams})
    precompile(Tuple{typeof(JSONRPC.send), JSONRPC.JSONRPCEndpoint, JSONRPC.NotificationType{TestItemServerProtocol.PassedParams}, TestItemServerProtocol.PassedParams})
    precompile(Tuple{typeof(JSONRPC.send), JSONRPC.JSONRPCEndpoint, JSONRPC.NotificationType{TestItemServerProtocol.ErroredParams}, TestItemServerProtocol.ErroredParams})
    precompile(Tuple{typeof(JSONRPC.send), JSONRPC.JSONRPCEndpoint, JSONRPC.NotificationType{TestItemServerProtocol.FailedParams}, TestItemServerProtocol.FailedParams})
    precompile(Tuple{typeof(JSONRPC.send), JSONRPC.JSONRPCEndpoint, JSONRPC.NotificationType{TestItemServerProtocol.SkippedStolenParams}, TestItemServerProtocol.SkippedStolenParams})

    # Debug session management
    precompile(Tuple{typeof(start_debug_backend), String, Nothing})
    precompile(Tuple{typeof(start_debug_backend), String, Function})
    precompile(Tuple{typeof(wait_for_debug_session)})
    precompile(Tuple{typeof(get_debug_session_if_present)})
end
