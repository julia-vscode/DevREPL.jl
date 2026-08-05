# Dispatch handler for JSONRPC messages from the test process.
# Posts ReactorMessages directly to the reactor channel.
JSONRPC.@message_dispatcher dispatch_testprocess_msg begin
    TestItemServerProtocol.started_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemStartedMsg(testrun_id, ps.id, params.testItemId))
        end
    end
    TestItemServerProtocol.passed_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemPassedMsg(testrun_id, ps.id, params.testItemId, params.duration, coalesce(params.coverage, nothing)))
        end
    end
    TestItemServerProtocol.failed_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemFailedMsg(testrun_id, ps.id, params.testItemId, params.messages, coalesce(params.duration, nothing)))
        end
    end
    TestItemServerProtocol.errored_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemErroredMsg(testrun_id, ps.id, params.testItemId, params.messages, coalesce(params.duration, nothing)))
        end
    end
    TestItemServerProtocol.skipped_stolen_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemSkippedStolenMsg(testrun_id, ps.id, params.testItemId))
        end
    end
end

function _truncate_for_log(s::AbstractString; max_bytes::Int=8192)
    if ncodeunits(s) <= max_bytes
        return s
    end
    # Find a valid character boundary at or before max_bytes
    i = max_bytes
    while i > 0 && !Base.isvalid(s, i)
        i -= 1
    end
    return SubString(s, 1, i) * "... ($(ncodeunits(s) - i) bytes truncated)"
end

struct TestProcessCrashException <: Exception
    testprocess_id::String
    exitcode::Union{Int,Nothing}
    term_signal::Union{Nothing,Int}
    captured_output::String
end

function start(testprocess_id, reactor_channel, ps::TestProcessState, env::ProcessEnv, debug_pipe_name, error_handler_file, crash_reporting_pipename, token)
    pipe_name = JSONRPC.generate_pipe_name()
    server = Sockets.listen(pipe_name)
    try

        testserver_script = joinpath(@__DIR__, "../testprocess/app/testserver_main.jl")

        pipe_out = Pipe()
        try

            coverage_arg = env.mode == "Coverage" ? "--code-coverage=user" : "--code-coverage=none"

            jlArgs = copy(env.juliaArgs)

            if env.juliaNumThreads!==nothing && env.juliaNumThreads == "auto"
                push!(jlArgs, "--threads=auto")
            end

            jlEnv = copy(ENV)

            # During precompilation, Julia restricts JULIA_LOAD_PATH to dependency paths only
            # (no "@" entry), which prevents child processes from using their own active project.
            if ccall(:jl_generating_output, Cint, ()) == 1
                delete!(jlEnv, "JULIA_LOAD_PATH")
            end

            for (k,v) in pairs(env.env)
                if v!==nothing
                    jlEnv[k] = v
                elseif haskey(jlEnv, k)
                    delete!(jlEnv, k)
                end
            end

            if env.juliaNumThreads!==nothing && env.juliaNumThreads!="auto" && env.juliaNumThreads!=""
                jlEnv["JULIA_NUM_THREADS"] = env.juliaNumThreads
            end

            error_handler_file = error_handler_file === nothing ? [] : [error_handler_file]
            crash_reporting_pipename = crash_reporting_pipename === nothing ? [] : [crash_reporting_pipename]

            cmd_args = `$(env.juliaCmd) $(env.juliaArgs) --check-bounds=yes --startup-file=no --history-file=no --depwarn=no $coverage_arg $testserver_script $pipe_name $(debug_pipe_name) $(error_handler_file...) $(crash_reporting_pipename...)`
            @info "Launching Julia test server process" testprocess_id pipe_name
            @debug "Full launch command" testprocess_id cmd=string(cmd_args) testserver_script mode=env.mode
            jl_process = open(
                pipeline(
                    Cmd(cmd_args, detach=false, env=jlEnv),
                    stdout = pipe_out,
                    stderr = pipe_out
                )
            )

            proc_kill_registration = CancellationTokens.register(token) do
                @info "Killing test process due to cancellation" testprocess_id
                try kill(jl_process) catch end
            end

            try # This try finally block closes the `proc_kill_registration`
                # Accumulate raw output from subprocess so we can log it if it crashes before connecting.
                raw_output_chunks = String[]
                raw_output_lock = ReentrantLock()

                @async try
                    begin_marker = "\x1f3805a0ad41b54562a46add40be31ca27"
                    end_marker = "\x1f4031af828c3d406ca42e25628bb0aa77"
                    buffer = ""
                    current_output_testitem_id = nothing
                    while !eof(pipe_out)
                        data = readavailable(pipe_out, token)
                        data_as_string = String(data)

                        # Capture raw output for crash diagnostics
                        lock(raw_output_lock) do
                            push!(raw_output_chunks, data_as_string)
                        end

                        buffer *= data_as_string

                        output_for_test_proc = IOBuffer()
                        output_for_test_items = Pair{Union{Nothing,String},IOBuffer}[]

                        i = 1
                        while i<=length(buffer)
                            might_be_begin_marker = false
                            might_be_end_marker = false

                            if current_output_testitem_id === nothing
                                j = 1
                                might_be_begin_marker = true
                                while i + j - 1<=length(buffer) && j <= length(begin_marker)
                                    if buffer[i + j - 1] != begin_marker[j] || nextind(buffer, i + j - 1) != i + j
                                        might_be_begin_marker = false
                                        break
                                    end
                                    j += 1
                                end
                                is_begin_marker = might_be_begin_marker && length(buffer) - i + 1 >= length(begin_marker)

                                if is_begin_marker
                                    ti_id_end_index = findfirst("\"", SubString(buffer, i))
                                    if ti_id_end_index === nothing
                                        break
                                    else
                                        current_output_testitem_id = SubString(buffer, i + length(begin_marker), i + ti_id_end_index.start - 2)
                                        i = nextind(buffer, i + ti_id_end_index.start - 1)
                                    end
                                elseif might_be_begin_marker
                                    break
                                end
                            else
                                j = 1
                                might_be_end_marker = true
                                while i + j - 1<=length(buffer) && j <= length(end_marker)
                                    if buffer[i + j - 1] != end_marker[j] || nextind(buffer, i + j - 1) != i + j
                                        might_be_end_marker = false
                                        break
                                    end
                                    j += 1
                                end
                                is_end_marker = might_be_end_marker && length(buffer) - i + 1 >= length(end_marker)

                                if is_end_marker
                                    current_output_testitem_id = nothing
                                    i = i + length(end_marker)
                                elseif might_be_end_marker
                                    break
                                end
                            end

                            if !might_be_begin_marker && !might_be_end_marker
                                print(output_for_test_proc, buffer[i])

                                if length(output_for_test_items) == 0 || output_for_test_items[end].first != current_output_testitem_id
                                    push!(output_for_test_items, current_output_testitem_id => IOBuffer())
                                end

                                output_for_ti = output_for_test_items[end].second
                                if !CancellationTokens.is_cancellation_requested(token)
                                    print(output_for_ti, buffer[i])
                                end

                                i = nextind(buffer, i)
                            end
                        end

                        buffer = buffer[i:end]

                        output_for_test_proc_as_string = String(take!(output_for_test_proc))

                        if length(output_for_test_proc_as_string) > 0
                            @debug "Forwarding process output chunk" testprocess_id output=_truncate_for_log(output_for_test_proc_as_string)
                            put!(
                                reactor_channel,
                                TestProcessOutputMsg(testprocess_id, output_for_test_proc_as_string)
                            )
                        end

                        for (k,v) in output_for_test_items
                            output_for_ti_as_string = String(take!(v))

                            if length(output_for_ti_as_string) > 0
                                testrun_id = ps.testrun_id
                                if testrun_id !== nothing
                                    @debug "Forwarding test item output chunk" testprocess_id testitem_id=something(k, missing) output=_truncate_for_log(output_for_ti_as_string)
                                    put!(
                                        reactor_channel,
                                        AppendOutputMsg(testrun_id, testprocess_id, k, replace(output_for_ti_as_string, "\n"=>"\r\n"))
                                    )
                                end
                            end
                        end
                    end
                catch err
                    if err isa CancellationTokens.OperationCanceledException
                        @debug "Output reading cancelled by token" testprocess_id
                    else
                        @error "Error reading test process output" testprocess_id exception=(err, catch_backtrace())
                    end
                end


                abort_accept_due_to_startup_failure_source = CancellationTokens.CancellationTokenSource()
                abort_accept_due_to_startup_failure_token = CancellationTokens.get_token(abort_accept_due_to_startup_failure_source)

                # Watch for subprocess exit before connection — if the process crashes during
                # startup (e.g. precompilation failure), close the server to unblock Sockets.accept.
                connection_established = Ref(false)
                @async try
                    wait(jl_process)
                    if !connection_established[]
                        if CancellationTokens.is_cancellation_requested(token)
                            @debug "Test process exited before connecting (cancellation requested)" testprocess_id exitcode=jl_process.exitcode pipe_name
                        else
                            CancellationTokens.cancel(abort_accept_due_to_startup_failure_source)
                        end                        
                    end
                catch err
                    @error "Error waiting for test process exit" testprocess_id exception=(err, catch_backtrace())
                end

                accept_combined_token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource(token, abort_accept_due_to_startup_failure_token))

                @info "Waiting for connection from test process" testprocess_id pipe_name
                try
                    socket = Sockets.accept(server, accept_combined_token)

                    try
                        connection_established[] = true

                        @info "Connection established" testprocess_id

                        endpoint = JSONRPC.JSONRPCEndpoint(socket, socket)
                        try
                            JSONRPC.start(endpoint)

                            @debug "Notifying reactor that process launched" testprocess_id
                            put!(reactor_channel, TestProcessLaunchedMsg(testprocess_id, jl_process, endpoint))

                            while true
                                msg = try
                                    JSONRPC.get_next_message(endpoint, token=token)
                                catch err
                                    if CancellationTokens.is_cancellation_requested(token) || err isa CancellationTokens.OperationCanceledException
                                        break
                                    else
                                        rethrow(err)
                                    end
                                end
                                @debug "Dispatching message from test server" testprocess_id method=msg.method

                                dispatch_testprocess_msg(endpoint, msg, (reactor_channel, ps))
                            end

                            put!(reactor_channel, TestProcessTerminatedMsg(testprocess_id, ps.testrun_id, ps.skip_remaining_on_termination))
                        finally
                            close(endpoint)
                        end 
                    finally
                        close(socket)
                    end
                catch err
                    if err isa CancellationTokens.OperationCanceledException && CancellationTokens.is_cancellation_requested(abort_accept_due_to_startup_failure_token)
                        captured_output = lock(raw_output_lock) do; join(raw_output_chunks); end
                        throw(
                            TestProcessCrashException(
                                testprocess_id,
                                jl_process.exitcode,
                                jl_process.termsignal,
                                captured_output
                            )
                        )
                    else
                        rethrow(err)
                    end
                end
            catch err
                if !(err isa CancellationTokens.OperationCanceledException)
                    try kill(jl_process) catch end # We wrap in try catch because on Windows this fails if the process is already dead.
                    wait(jl_process)
                    put!(reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal, jl_process.exitcode, jl_process.termsignal))
                else
                    put!(reactor_channel, TestProcessTerminatedMsg(testprocess_id, ps.testrun_id, ps.skip_remaining_on_termination))
                end
            finally
                close(proc_kill_registration)
            end
        finally
            close(pipe_out)
        end
    finally
        close(server)
    end
    
end
