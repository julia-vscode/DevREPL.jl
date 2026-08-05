module TestItemServer

include("pkg_imports.jl")

import .JSONRPC: @dict_readable
import .CoverageTools: LCOV, amend_coverage_from_src!
import .CancellationTokens: CancellationToken
import Test, Pkg, Sockets
import Logging

include("../../../shared/testserver_protocol.jl")
include("helper.jl")

mutable struct Testsetup
    name::String
    kind::Symbol
    uri::String
    line::Int
    column::Int
    code::String
    evaled::Bool
end

mutable struct TestProcessState
    endpoint::JSONRPC.JSONRPCEndpoint

    test_setups::Dict{Tuple{String,Symbol},Testsetup}
    mode::String
    coverage_root_uris::Union{Nothing,Vector{String}}
    log_level::Base.CoreLogging.LogLevel

    testitems_channel::Channel{Vector{TestItemServerProtocol.RunTestItem}}
    stolen_testitem_ids_channel::Channel{Vector{String}}
    wakeup_channel::Channel{Nothing}

    function TestProcessState(endpoint::JSONRPC.JSONRPCEndpoint)
        return new(
            endpoint,
            Dict{Tuple{String,Symbol},Testsetup}(),
            "",
            nothing,
            Logging.Info,
            Channel{Vector{TestItemServerProtocol.RunTestItem}}(Inf),
            Channel{Vector{String}}(Inf),
            Channel{Nothing}(Inf)
        )
    end
end

const TESTITEMSERVER_DIR = @__DIR__
const JULIA_BASE_DIR = normpath(joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "base"))
const JULIA_STDLIB_DIR = Sys.STDLIB

function is_infrastructure_frame(file::AbstractString)
    startswith(file, TESTITEMSERVER_DIR) ||
    startswith(file, JULIA_BASE_DIR) ||
    startswith(file, JULIA_STDLIB_DIR)
end

const DEBUG_SESSION = Ref{Channel{DebugAdapter.DebugSession}}()

function __init__()
    DEBUG_SESSION[] = Channel{DebugAdapter.DebugSession}(1)

    Core.eval(Main, :(module Testsetups end))
end

function withpath(f, path)
    tls = task_local_storage()
    hassource = haskey(tls, :SOURCE_PATH)
    hassource && (path′ = tls[:SOURCE_PATH])
    tls[:SOURCE_PATH] = path
    try
        return f()
    finally
        hassource ? (tls[:SOURCE_PATH] = path′) : delete!(tls, :SOURCE_PATH)
    end
end

function revise_request(::Nothing, state::TestProcessState, token::CancellationToken)
    try
        Revise.revise(throw=true)
        return "success"
    catch err
        # Base.display_error(err, catch_backtrace())
        return "failed"
    end
end

function format_error_message(err, bt)
    try
        actual_err = err isa LoadError ? err.error : err
        return Base.invokelatest(sprint, showerror, actual_err)
    catch err
        return "Error while trying to format an error message"
    end
end

function find_error_location(st)
    for frame in st
        frame.from_c && continue
        file = string(frame.file)
        if !isabspath(file)
            resolved = Base.find_source_file(file)
            if resolved !== nothing
                file = resolved
            end
        end
        if !is_infrastructure_frame(file)
            return (file, frame.line)
        end
    end
    return (string(st[1].file), st[1].line)
end

function backtrace_to_stackframes(bt)
    frames = try
        stacktrace(bt)
    catch
        return missing
    end

    result = TestItemServerProtocol.TestMessageStackFrame[]
    resolved_files = String[]

    for frame in frames
        frame.from_c && continue

        file = string(frame.file)

        if !isabspath(file)
            resolved = Base.find_source_file(file)
            if resolved !== nothing
                file = resolved
            end
        end

        uri = isabspath(file) ? filepath2uri(file) : missing
        location = uri !== missing ? TestItemServerProtocol.Location(uri, TestItemServerProtocol.Position(frame.line, 1)) : missing

        push!(result, TestItemServerProtocol.TestMessageStackFrame(
            label = string(frame.func),
            uri = uri,
            location = location,
        ))
        push!(resolved_files, file)
    end

    # Truncate trailing infrastructure frames (TestItemServer, Julia base, stdlib)
    # while preserving base/stdlib frames that appear within the user's call chain
    last_user_frame = findlast(f -> !is_infrastructure_frame(f), resolved_files)
    if last_user_frame === nothing
        return missing
    end
    resize!(result, last_user_frame)

    return isempty(result) ? missing : result
end

function parse_backtrace_string(bt_str::AbstractString)
    (bt_str === nothing || isempty(bt_str)) && return missing

    # Each frame spans two lines:
    #  [N] func_signature
    #    @ Module path:line [inlined]
    # The path may be a Windows path like C:\dir\file.jl:42
    # so we match the colon-digit at the END to get the line number.
    frame_re = r"^\s*\[\d+\]\s+(.+?)(?:\s+\(repeats \d+ times\))?$"m
    location_re = r"^\s*@\s+\S+\s+(.+):(\d+)"m

    func_matches = collect(eachmatch(frame_re, bt_str))
    loc_matches  = collect(eachmatch(location_re, bt_str))

    isempty(func_matches) && return missing

    result = TestItemServerProtocol.TestMessageStackFrame[]
    resolved_files = String[]

    for idx in eachindex(func_matches)
        label = strip(func_matches[idx].captures[1])

        file = ""
        line = 0
        if idx <= length(loc_matches)
            file = strip(string(loc_matches[idx].captures[1]))
            # Remove trailing " [inlined]" if present
            file = replace(file, r"\s+\[inlined\]$" => "")
            line = parse(Int, loc_matches[idx].captures[2])
        end

        if !isempty(file) && !isabspath(file)
            resolved = Base.find_source_file(file)
            if resolved !== nothing
                file = resolved
            end
        end

        uri = (!isempty(file) && isabspath(file)) ? filepath2uri(file) : missing
        location = uri !== missing ? TestItemServerProtocol.Location(uri, TestItemServerProtocol.Position(line, 1)) : missing

        push!(result, TestItemServerProtocol.TestMessageStackFrame(
            label = string(label),
            uri = uri,
            location = location,
        ))
        push!(resolved_files, file)
    end

    # Truncate trailing infrastructure frames, same as backtrace_to_stackframes
    last_user_frame = findlast(f -> !isempty(f) && !is_infrastructure_frame(f), resolved_files)
    if last_user_frame === nothing
        return missing
    end
    resize!(result, last_user_frame)

    return isempty(result) ? missing : result
end

function clear_coverage_data()
    @static if VERSION >= v"1.11.0-rc2"
        try
            @ccall jl_clear_coverage_data()::Cvoid
        catch err
            # TODO Call global error handler
        end
    end
end

function collect_coverage_data!(coverage_results, roots)
    @static if VERSION >= v"1.11.0-rc2"
        lcov_filename = tempname() * ".info"
        @ccall jl_write_coverage_data(lcov_filename::Cstring)::Cvoid
        cov_info = try
            LCOV.readfile(lcov_filename)
        finally
            rm(lcov_filename)
        end

        filter!(i->isabspath(i.filename) && any(j->startswith(filepath2uri(i.filename), j), roots) && isfile(i.filename), cov_info)

        append!(coverage_results, cov_info)
    end
end

function process_coverage_data(coverage_results)
    if length(coverage_results) == 0
        return missing
    end

    merged_coverage = CoverageTools.merge_coverage_counts(coverage_results)

    coverage_info = TestItemServerProtocol.FileCoverage[]

    for i in merged_coverage
        file_cov = CoverageTools.FileCoverage(i.filename, read(i.filename, String), i.coverage)

        amend_coverage_from_src!(file_cov)

        push!(coverage_info, TestItemServerProtocol.FileCoverage(filepath2uri(file_cov.filename), file_cov.coverage))
    end

    return coverage_info
end

function run_testitem(endpoint, params::TestItemServerProtocol.RunTestItem, mode::String, coverage_root_uris::Union{Nothing,Vector{String}}, state::TestProcessState)
    JSONRPC.send(
        endpoint,
        TestItemServerProtocol.started_notification_type,
        TestItemServerProtocol.StartedParams(
            testItemId = params.id,
        )
    )

    working_dir = dirname(uri2filepath(params.uri))
    cd(working_dir)

    coverage_results = CoverageTools.FileCoverage[] # This will hold the results of various coverage sprints

    for i in params.testSetups
        if !haskey(state.test_setups, (params.packageUri, Symbol(i)))
            return (
                TestItemServerProtocol.errored_notification_type,
                TestItemServerProtocol.ErroredParams(
                    testItemId = params.id,
                    messages = [
                        TestItemServerProtocol.TestMessage(
                            "The specified testsetup $i does not exist.",
                            TestItemServerProtocol.Location(
                                params.uri,
                                TestItemServerProtocol.Position(params.line, 1)
                            )
                        )
                    ],
                    duration = missing
                )
            )
        end

        setup_details = state.test_setups[(params.packageUri, Symbol(i))]

        if setup_details.kind==:module && !setup_details.evaled
            mod = Core.eval(Main.Testsetups, :(module $(Symbol(i)) end))

            code = string('\n'^(setup_details.line-1), ' '^(setup_details.column-1), setup_details.code)

            filepath = uri2filepath(setup_details.uri)

            t0 = time_ns()
            try
                withpath(filepath) do
                    Logging.with_logger(Logging.ConsoleLogger(stderr, state.log_level)) do
                        Base.invokelatest(include_string, mod, code, filepath)
                    end
                end
                setup_details.evaled = true
            catch err
                elapsed_time = (time_ns() - t0) / 1e6 # Convert to milliseconds

                bt = catch_backtrace()
                st = stacktrace(bt)

                error_message = format_error_message(err, bt)
                stack_frames = backtrace_to_stackframes(bt)

                error_filepath, error_line = find_error_location(st)

                return (
                    TestItemServerProtocol.errored_notification_type,
                    TestItemServerProtocol.ErroredParams(
                        testItemId = params.id,
                        messages = [
                            TestItemServerProtocol.TestMessage(
                                message = error_message,
                                location = TestItemServerProtocol.Location(
                                    isabspath(error_filepath) ? filepath2uri(error_filepath) : "",
                                    TestItemServerProtocol.Position(max(1, error_line), 1)
                                ),
                                stackTrace = stack_frames,
                            )
                        ],
                        duration = missing
                    )
                )
            end
        end
    end

    mod = Core.eval(Main, :(module $(gensym()) end))

    if params.useDefaultUsings
        try
            Core.eval(mod, :(using Test))
        catch
            return (
                TestItemServerProtocol.errored_notification_type,
                TestItemServerProtocol.ErroredParams(
                    testItemId = params.id,
                    messages = [
                        TestItemServerProtocol.TestMessage(
                            "Unable to load the `Test` package. Please ensure that `Test` is listed as a test dependency in the Project.toml for the package.",
                            TestItemServerProtocol.Location(
                                params.uri,
                                TestItemServerProtocol.Position(params.line, 1)
                            )
                        )
                    ],
                    duration = missing
                )
            )
        end

        if params.packageName!=""
            try
                mode == "Coverage" && clear_coverage_data()

                try
                    Core.eval(mod, :(using $(Symbol(params.packageName))))
                finally
                    mode == "Coverage" && collect_coverage_data!(coverage_results, coverage_root_uris)
                end
            catch err
                bt = catch_backtrace()
                error_message = format_error_message(err, bt)
                stack_frames = backtrace_to_stackframes(bt)

                return (
                    TestItemServerProtocol.errored_notification_type,
                    TestItemServerProtocol.ErroredParams(
                        testItemId = params.id,
                        messages = [
                            TestItemServerProtocol.TestMessage(
                                message = error_message,
                                location = TestItemServerProtocol.Location(
                                    params.uri,
                                    TestItemServerProtocol.Position(params.line, 1)
                                ),
                                stackTrace = stack_frames,
                            )
                        ],
                        duration = missing
                    )
                )
            end
        end
    end

    for i in params.testSetups
        testsetup_details = state.test_setups[(params.packageUri,Symbol(i))]

        try
            if testsetup_details.kind==:module
                Core.eval(mod, :(using ..Testsetups.$(Symbol(i))))
            elseif testsetup_details.kind==:snippet
                testsnippet_filepath = uri2filepath(testsetup_details.uri)
                testsnippet_code = string('\n'^(testsetup_details.line-1), ' '^(testsetup_details.column-1), testsetup_details.code)

                withpath(testsnippet_filepath) do
                    if mode == "Debug"
                        debug_session = wait_for_debug_session()
                        DebugAdapter.debug_code(debug_session, mod, testsnippet_code, testsnippet_filepath)
                    else
                        mode == "Coverage" && clear_coverage_data()
                        try
                            Logging.with_logger(Logging.ConsoleLogger(stderr, state.log_level)) do
                                Base.invokelatest(include_string, mod, testsnippet_code, testsnippet_filepath)
                            end
                        finally
                            mode == "Coverage" && collect_coverage_data!(coverage_results, coverage_root_uris)
                        end
                    end
                end
            else
                error("Unknown testsetup kind $(i.kind).")
            end
        catch err
            bt = catch_backtrace()
            Base.invokelatest(Base.display_error, err, bt)
            stack_frames = backtrace_to_stackframes(bt)
            return (
                TestItemServerProtocol.errored_notification_type,
                TestItemServerProtocol.ErroredParams(
                    testItemId = params.id,
                    messages = [
                        TestItemServerProtocol.TestMessage(
                            message = "Unable to load the `$i` testsetup.",
                            location = TestItemServerProtocol.Location(
                                params.uri,
                                TestItemServerProtocol.Position(params.line, 1)
                            ),
                            stackTrace = stack_frames,
                        )
                    ],
                    duration = missing
                )
            )

        end
    end

    filepath = uri2filepath(params.uri)

    code = string('\n'^(params.line-1), ' '^(params.column-1), params.code)


    elapsed_time = UInt64(0)

    inner_test_function = () -> begin
        t0 = time_ns()
        try
            withpath(filepath) do

                if mode == "Debug"
                    debug_session = wait_for_debug_session()
                    DebugAdapter.debug_code(debug_session, mod, code, filepath)
                else
                    mode == "Coverage" && clear_coverage_data()
                    try
                        Logging.with_logger(Logging.ConsoleLogger(stderr, state.log_level)) do
                            Base.invokelatest(include_string, mod, code, filepath)
                        end
                    finally
                        mode == "Coverage" && collect_coverage_data!(coverage_results, coverage_root_uris)
                    end
                end
                elapsed_time = (time_ns() - t0) / 1e6 # Convert to milliseconds
            end

            return nothing
        catch err
            elapsed_time = (time_ns() - t0) / 1e6 # Convert to milliseconds

            bt = catch_backtrace()
            st = stacktrace(bt)

            error_message = format_error_message(err, bt)
            stack_frames = backtrace_to_stackframes(bt)

            error_filepath, error_line = find_error_location(st)

            return (
                TestItemServerProtocol.errored_notification_type,
                TestItemServerProtocol.ErroredParams(
                    testItemId = params.id,
                    messages = [
                        TestItemServerProtocol.TestMessage(
                            message = error_message,
                            location = TestItemServerProtocol.Location(
                                isabspath(error_filepath) ? filepath2uri(error_filepath) : "",
                                TestItemServerProtocol.Position(max(1, error_line), 1)
                            ),
                            stackTrace = stack_frames,
                        )
                    ],
                    duration = missing
                )
            )
        end
    end

    ts = Test.DefaultTestSet("$filepath:$(params.name)")

    ret = nothing

    @static if VERSION < v"1.13.0-"
        Test.push_testset(ts)
        try
            ret = inner_test_function()
        finally
            ts = Test.pop_testset()
        end
    else
        Test.@with_testset ts begin
            ret = inner_test_function()
        end
    end

    if ret !== nothing
        return ret
    end

    try
        Test.finish(ts)

        return (
            TestItemServerProtocol.passed_notification_type,
            TestItemServerProtocol.PassedParams(
                testItemId = params.id,
                duration = elapsed_time,
                coverage = process_coverage_data(coverage_results)
            )
        )
    catch err
        if err isa Test.TestSetException
            failed_tests = Test.filter_errors(ts)

            return (
                TestItemServerProtocol.failed_notification_type,
                TestItemServerProtocol.FailedParams(
                    testItemId = params.id,
                    messages = [ create_test_message_for_failed(i) for i in failed_tests],
                    duration = elapsed_time
                )
            )
        else
            rethrow(err)
        end
    end
end

function run_testitems_batch_request(params::TestItemServerProtocol.RunTestItemsRequestParams, state::TestProcessState, token::CancellationToken)
    put!(state.testitems_channel, params.testItems)
    put!(state.wakeup_channel, nothing)

    return nothing
end

function create_test_message_for_failed(i)
    (expected, actual) = extract_expected_and_actual(i)

    stack_frames = if :backtrace in fieldnames(typeof(i)) && i.backtrace isa AbstractString && !isempty(i.backtrace)
        parse_backtrace_string(i.backtrace)
    else
        missing
    end

    return TestItemServerProtocol.TestMessage(
        message = Base.invokelatest(sprint, Base.show, i),
        expectedOutput = expected,
        actualOutput = actual,
        location = TestItemServerProtocol.Location(filepath2uri(string(i.source.file)), TestItemServerProtocol.Position(i.source.line, 1)),
        stackTrace = stack_frames,
    )
end

function extract_expected_and_actual(result)
    actual = nothing
    expected = nothing

    if isa(result, Test.Fail)
        s = result.data

        if isa(s, String)
            m = match(r"\"(.*)\" == \"(.*)\""s, s)
            if m !== nothing
                try
                    expected = unescape_string(m.captures[2])
                    actual = unescape_string(m.captures[1])
                catch err
                    # theoretically possible if a user registers a Fail instance that matches
                    # above regexp, but doesn't contain two escaped strings.
                    # just return nothing in this unlikely case, meaning no diff will be shown.
                end
            else
                # Now try the version without quotation marks
                m = match(r"(.*) == (.*)"s, s)
                if m !== nothing
                    try
                        expected = unescape_string(m.captures[2])
                        actual = unescape_string(m.captures[1])
                    catch err
                        # theoretically possible if a user registers a Fail instance that matches
                        # above regexp, but doesn't contain two escaped strings.
                        # just return nothing in this unlikely case, meaning no diff will be shown.
                    end
                end
            end
        end
    end

    if actual !== nothing && expected !== nothing
        return (expected, actual)
    else
        return (missing, missing)
    end
end



function start_debug_backend(debug_pipename::String, error_handler)
    ready = Channel{Bool}(1)
    @async try
        server = Sockets.listen(debug_pipename)

        put!(ready, true)

        while true
            conn = Sockets.accept(server)

            debug_session = DebugAdapter.DebugSession(conn)

            global DEBUG_SESSION

            put!(DEBUG_SESSION[], debug_session)

            try
                run(debug_session, error_handler)
            finally
                take!(DEBUG_SESSION[])
            end
        end
    catch err
        bt = catch_backtrace()

        if error_handler !== nothing
            Base.invokelatest(error_handler, err, bt)
        end

        @error "The TestItemServer debug task failed." exception = (err, bt)
                
        exit(1) 
    end

    take!(ready)
end

function wait_for_debug_session()
    @info "Now waiting for debug session"
    fetch(DEBUG_SESSION[])
end

function get_debug_session_if_present()
    if isready(DEBUG_SESSION[])
        return fetch(DEBUG_SESSION[])
    else
        return nothing
    end
end


function activate_env_request(params::TestItemServerProtocol.ActivateEnvParams, state::TestProcessState, token::CancellationToken)
    try
        if params.projectUri===missing
            @static if VERSION >= v"1.5.0"
                Pkg.activate(temp=true)
            else
                temp_path = mktempdir()
                Pkg.activate(temp_path)
            end

            Pkg.develop(Pkg.PackageSpec(path=uri2filepath(params.packageUri)))

            TestEnv.activate(params.packageName)
        else
            Pkg.activate(uri2filepath(params.projectUri))

            if params.packageName!==missing
                TestEnv.activate(params.packageName)
            end
        end

        return TestItemServerProtocol.ActivateEnvResult(
            status = "success",
            error = missing
        )
    catch err
        bt = catch_backtrace()
        error_message = format_error_message(err, bt)

        return TestItemServerProtocol.ActivateEnvResult(
            status = "failed",
            error = error_message
        )
    end
end

function parse_log_level(s::Symbol)::Base.CoreLogging.LogLevel
    s === :Debug && return Logging.Debug
    s === :Info  && return Logging.Info
    s === :Warn  && return Logging.Warn
    s === :Error && return Logging.Error
    return Logging.Info
end

function configure_test_run_request(params::TestItemServerProtocol.ConfigureTestRunRequestParams, state::TestProcessState, token::CancellationToken)
    state.mode = params.mode
    state.log_level = parse_log_level(Symbol(params.logLevel))
    state.coverage_root_uris = coalesce(params.coverageRootUris, nothing)

    setups_to_remove = setdiff(keys(state.test_setups), map(i->(i.packageUri,Symbol(i.name)), params.testSetups))
    for i in setups_to_remove
        delete!(state.test_setups, i)
    end

    for i in params.testSetups
        key = (i.packageUri, Symbol(i.name))
        if !haskey(state.test_setups, key)
            state.test_setups[key] = Testsetup(
                i.name,
                Symbol(i.kind),
                i.uri,
                i.line,
                i.column,
                i.code,
                false
            )
        else
            val = state.test_setups[key]

            if val.code != i.code || val.kind != i.kind
                val.evaled = false
                val.code = i.code
                val.kind = Symbol(i.kind)
            end

            val.uri = i.uri
            val.line = i.line
            val.column = i.column
            val.name = i.name
        end
    end
end

function steal_testitems_request(params::TestItemServerProtocol.StealTestItemsRequestParams, state::TestProcessState, token::CancellationToken)
    put!(state.stolen_testitem_ids_channel, params.testItemIds)
    put!(state.wakeup_channel, nothing)

    return nothing
end

function shutdown_request(::Nothing, state::TestProcessState, token::CancellationToken)
    return nothing
end

JSONRPC.@message_dispatcher dispatch_msg begin
    TestItemServerProtocol.testserver_revise_request_type => revise_request
    TestItemServerProtocol.testserver_activate_env_request_type => activate_env_request
    TestItemServerProtocol.configure_testrun_request_type => configure_test_run_request
    TestItemServerProtocol.testserver_run_testitems_batch_request_type => run_testitems_batch_request
    TestItemServerProtocol.testserver_steal_testitems_request_type => steal_testitems_request
    TestItemServerProtocol.testserver_shutdown_request_type => shutdown_request
end

function runner_loop(state::TestProcessState)
    stolen_testitem_ids = String[]
    testitems = TestItemServerProtocol.RunTestItem[]



    while true
        if isready(state.stolen_testitem_ids_channel)
            append!(stolen_testitem_ids, take!(state.stolen_testitem_ids_channel))
        end

        if length(testitems) == 0
            if isready(state.testitems_channel)
                append!(testitems, take!(state.testitems_channel))
            end
        end

        if length(testitems) == 0
            for id in stolen_testitem_ids
                JSONRPC.send(
                    state.endpoint,
                    TestItemServerProtocol.skipped_stolen_notification_type,
                    TestItemServerProtocol.SkippedStolenParams(
                        testItemId = id
                    )
                )
            end
            empty!(stolen_testitem_ids)
        else
            current_testitem = popfirst!(testitems)

            idx = findfirst(i->i==current_testitem.id, stolen_testitem_ids)
            if idx !== nothing
                deleteat!(stolen_testitem_ids, idx)

                JSONRPC.send(
                    state.endpoint,
                    TestItemServerProtocol.skipped_stolen_notification_type,
                    TestItemServerProtocol.SkippedStolenParams(
                        testItemId = current_testitem.id
                    )
                )
            else
                

                # Save the correct environment state set by activate_env_request, so we can
                # restore it after we run the test item. A @testitem might call Pkg.activate() or
                # cd() which would otherwise corrupt the environment for subsequent items.
                saved_project = Base.ACTIVE_PROJECT[]
                saved_load_path = copy(LOAD_PATH)
                saved_cwd = pwd()

                print(stderr, "\x1f3805a0ad41b54562a46add40be31ca27", "$(current_testitem.id)\"", "")
                flush(stderr)
                ret = run_testitem(state.endpoint, current_testitem, state.mode, state.coverage_root_uris, state)
                print(stderr, "\x1f4031af828c3d406ca42e25628bb0aa77")
                flush(stderr)

                # Restore environment state in case the previous test item mutated it
                Base.ACTIVE_PROJECT[] = saved_project
                append!(empty!(LOAD_PATH), saved_load_path)
                cd(saved_cwd)

                JSONRPC.send(
                    state.endpoint,
                    ret[1],
                    ret[2]
                )
            end
        end


        # We now check again for stolen test items, as we might have received some
        # while we were running the last test item
        if isready(state.stolen_testitem_ids_channel)
            append!(stolen_testitem_ids, take!(state.stolen_testitem_ids_channel))
        end

        if length(testitems)==0 && length(stolen_testitem_ids)==0
            take!(state.wakeup_channel)
        end
    end
end

function serve(pipename, debug_pipename, error_handler=nothing)
    if debug_pipename!==nothing
        start_debug_backend(debug_pipename, error_handler)
    end

    conn = Sockets.connect(pipename)

    endpoint = JSONRPC.JSONRPCEndpoint(conn, conn)

    JSONRPC.start(endpoint)

    state = TestProcessState(endpoint)

    @async try
        runner_loop(state)
    catch err
        bt = catch_backtrace()

        if error_handler !== nothing
            Base.invokelatest(error_handler, err, bt)
        end

        @error "The TestItemServer runner loop crashed with an error." exception = (err, bt)
        
        exit(1)
    end

    while true
        msg = JSONRPC.get_next_message(endpoint)

        if msg.method == "testserver/shutdown"
            dispatch_msg(endpoint, msg, state)
            break
        else
            @async try
                dispatch_msg(endpoint, msg, state)
            catch err
                bt = catch_backtrace()

                if error_handler !== nothing
                    Base.invokelatest(error_handler, err, bt)
                end
                
                @error "The TestItemServer failed to dispatch a message." exception = (err, bt)
                
                exit(1)                
            end
        end
    end
end

include("precompile.jl")
_precompile_()

end
