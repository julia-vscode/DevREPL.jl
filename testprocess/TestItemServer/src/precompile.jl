function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

    # URI helpers (called on every test run)
    precompile(Tuple{typeof(uri2filepath), String})
    precompile(Tuple{typeof(filepath2uri), String})
    precompile(Tuple{typeof(withpath), Function, String})
    precompile(Tuple{typeof(is_infrastructure_frame), String})

    # Error formatting
    precompile(Tuple{typeof(format_error_message), Any, Any})
    precompile(Tuple{typeof(find_error_location), Vector{Base.StackTraces.StackFrame}})
    precompile(Tuple{typeof(parse_backtrace_string), String})
    precompile(Tuple{typeof(parse_log_level), Symbol})

    # Test result formatting
    precompile(Tuple{typeof(extract_expected_and_actual), Test.Fail})

    # Coverage
    precompile(Tuple{typeof(process_coverage_data), Vector{CoverageTools.FileCoverage}})
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
