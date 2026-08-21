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
            put!(reactor_channel, TestItemPassedMsg(testrun_id, ps.id, params.testItemId, params.duration, coalesce(params.coverage, nothing), _convert_perf_stats(params.perf)))
        end
    end
    TestItemServerProtocol.failed_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemFailedMsg(testrun_id, ps.id, params.testItemId, params.messages, coalesce(params.duration, nothing), _convert_perf_stats(params.perf)))
        end
    end
    TestItemServerProtocol.errored_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemErroredMsg(testrun_id, ps.id, params.testItemId, params.messages, coalesce(params.duration, nothing), _convert_perf_stats(params.perf)))
        end
    end
    TestItemServerProtocol.skipped_stolen_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemSkippedStolenMsg(testrun_id, ps.id, params.testItemId))
        end
    end
    TestItemServerProtocol.skipped_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemSkippedMsg(testrun_id, ps.id, params.testItemId, coalesce(params.reason, nothing)))
        end
    end
    TestItemServerProtocol.setup_evaluated_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        put!(reactor_channel, TestSetupEvaluatedMsg(ps.id, params.packageUri, params.name, coalesce(params.durationMs, nothing), coalesce(params.output, "")))
    end
end

function _convert_perf_stats(perf::Union{Missing,TestItemServerProtocol.PerfStatsParams})
    perf === missing && return nothing
    return PerfStats(
        coalesce(perf.elapsed, nothing),
        coalesce(perf.bytes, nothing),
        coalesce(perf.allocs, nothing),
        coalesce(perf.gctime, nothing),
        coalesce(perf.compile_time, nothing),
        coalesce(perf.recompile_time, nothing),
    )
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

# Number of interactive threads reserved in a test process. The main task — and therefore
# the runner loop and every test item — occupies the first; the hang watchdog gets the
# second, which is what lets it run while an item has the main thread wedged. Only the
# *default* pool is sized from the user's `juliaNumThreads`, so `Threads.nthreads()` inside
# a test item is unchanged by this. Requires Julia >= 1.9, which is where `--threads=N,M`
# and the interactive threadpool arrived.
const WATCHDOG_INTERACTIVE_THREADS = 2

# How the diagnostics file reaches the test process, and the exit code it uses to say it is
# stopping for memory recycling rather than crashing. Both are duplicated in the test
# server (`testprocess/TestItemServer/src/watchdog.jl` and `TestItemServer.jl`); they are
# not in `shared/testserver_protocol.jl` because they are not part of the JSONRPC schema.
const DIAGNOSTICS_FILE_ENV_VAR = "JULIA_TESTITEMSERVER_DIAGNOSTICS_FILE"
const MEMORY_RECYCLE_EXIT_CODE = 66

# Where a test process writes its hang diagnostics. Derived from the process id rather than
# tracked on the process state, so the controller can find it again from the timeout handler.
_diagnostics_file_path(testprocess_id::AbstractString) =
    joinpath(tempdir(), "testitemserver-diagnostics-$(testprocess_id).log")

# How long the controller waits past an item's timeout before killing its test process, so
# the process's watchdog has time to write a dump first. What has to fit: the watchdog fires
# `WATCHDOG_LEAD_MS` before the timeout, then symbolicates every live task's backtrace, then
# samples a CPU profile for a second and pays for a cold `Profile.print`. On a slow, cold CI
# runner that took more than five seconds; the dump is written in sections so a partial one
# survives, but ten gives the whole thing room. Only a timed-out item pays this latency.
const WATCHDOG_KILL_GRACE_SECONDS = 10.0

# Whatever the test process's watchdog has written so far, or `nothing` when it wrote
# nothing. Consuming the file keeps a second timeout on the same process from replaying an
# earlier item's dump.
function _read_diagnostics(testprocess_id::AbstractString)
    file = _diagnostics_file_path(testprocess_id)
    return try
        isfile(file) || return nothing
        content = read(file, String)
        try rm(file, force=true) catch end
        isempty(content) ? nothing : content
    catch err
        @debug "Could not read hang diagnostics" testprocess_id exception=(err, catch_backtrace())
        nothing
    end
end

# Build the `--threads` value for a test process, folding in the interactive threads the
# watchdog needs. `juliaNumThreads` may already carry an `N,M` pair, in which case we only
# raise `M` far enough to leave the watchdog a thread of its own.
function _thread_spec(juliaNumThreads::Union{Nothing,String})
    spec = juliaNumThreads === nothing || juliaNumThreads == "" ? "1" : juliaNumThreads
    parts = split(spec, ',')
    if length(parts) == 1
        return "$(parts[1]),$WATCHDOG_INTERACTIVE_THREADS"
    end
    interactive = tryparse(Int, parts[2])
    interactive === nothing && return spec # e.g. "auto,auto" — leave the user's spec alone
    return "$(parts[1]),$(max(interactive, WATCHDOG_INTERACTIVE_THREADS))"
end

# Give a process that has closed its pipe a short window to finish exiting under its own
# power. Returns `true` if it did. Used before killing on an I/O error, so that a worker
# which is *deliberately* exiting is not SIGTERMed mid-`exit` and made to look like a crash.
function _wait_for_self_exit(p::Base.Process, timeout_secs::Real)
    deadline = time() + timeout_secs
    while process_running(p) && time() < deadline
        sleep(0.02)
    end
    return !process_running(p)
end

# Bring a child down and *wait until it is actually gone*, escalating if it does not go on
# its own. `kill` alone is SIGTERM (TerminateProcess on Windows), which a child that is busy
# in non-yielding code, or that has SIGTERM blocked, can sit through indefinitely. Every
# caller that afterwards reports the process as terminated must go through here first:
# posting `TestProcessTerminatedMsg` for a child that is still alive makes the controller
# forget it, so nothing ever kills it — that is exactly how test processes outlived VS Code.
function _terminate_and_wait!(jl_process::Base.Process, testprocess_id; grace::Real=5.0)
    if process_running(jl_process)
        try kill(jl_process) catch end # Windows throws if it is already dead.
    end
    if process_running(jl_process) && !_wait_for_self_exit(jl_process, grace)
        @warn "Test process did not exit after SIGTERM; killing it" testprocess_id
        try
            @static if Sys.iswindows()
                kill(jl_process)
            else
                kill(jl_process, Base.SIGKILL)
            end
        catch
        end
    end
    try wait(jl_process) catch end
    return nothing
end

struct TestProcessCrashException <: Exception
    testprocess_id::String
    exitcode::Union{Int,Nothing}
    term_signal::Union{Nothing,Int}
    captured_output::String
end

function start(testprocess_id, reactor_channel, ps::TestProcessState, env::ProcessEnv, debug_pipe_name, error_handler_file, crash_reporting_pipename, julia_version, token)
    pipe_name = JSONRPC.generate_pipe_name()
    diagnostics_file = _diagnostics_file_path(testprocess_id)
    server = Sockets.listen(pipe_name)
    try

        testserver_script = joinpath(@__DIR__, "../testprocess/app/testserver_main.jl")

        pipe_out = Pipe()
        try

            coverage_arg = env.mode == "Coverage" ? "--code-coverage=user" : "--code-coverage=none"

            jlArgs = copy(env.juliaArgs)

            # "auto" is Julia's default; only pass the flag when overriding. Old Julia
            # versions (< 1.8) reject `--check-bounds=auto` outright, so omitting it is
            # also required for them to launch at all.
            if env.check_bounds != "auto"
                push!(jlArgs, "--check-bounds=$(env.check_bounds)")
            end

            # Without this the test process would see a pipe rather than a terminal and
            # turn color off, so nothing a test item prints could ever carry it.
            env.color && push!(jlArgs, "--color=yes")

            # Reserve the watchdog's interactive thread where the Julia version supports it,
            # otherwise keep the pre-existing behaviour exactly (the watchdog then degrades
            # to "no diagnostic dump", which `start_watchdog!` handles).
            watchdog_threads_supported = julia_version !== nothing && julia_version >= v"1.9"

            if watchdog_threads_supported
                push!(jlArgs, "--threads=$(_thread_spec(env.juliaNumThreads))")
            elseif env.juliaNumThreads!==nothing && env.juliaNumThreads == "auto"
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

            # Redundant once `--threads` is on the command line, and it would only confuse
            # the picture if the two disagreed.
            if !watchdog_threads_supported && env.juliaNumThreads!==nothing && env.juliaNumThreads!="auto" && env.juliaNumThreads!=""
                jlEnv["JULIA_NUM_THREADS"] = env.juliaNumThreads
            end

            # Set after the user's env overlay so a test environment cannot accidentally
            # redirect the diagnostics file.
            jlEnv[DIAGNOSTICS_FILE_ENV_VAR] = diagnostics_file

            error_handler_file = error_handler_file === nothing ? [] : [error_handler_file]
            crash_reporting_pipename = crash_reporting_pipename === nothing ? [] : [crash_reporting_pipename]

            cmd_args = `$(env.juliaCmd) $(jlArgs) --startup-file=no --history-file=no --depwarn=no $coverage_arg $testserver_script $pipe_name $(debug_pipe_name) $(error_handler_file...) $(crash_reporting_pipename...)`
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
                        ps.last_output_at = time()
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
                        # A warning, not an error: the process itself is unaffected and
                        # keeps reporting results over JSON-RPC — only its console output
                        # stops being forwarded. Under the crash-reporting logger an
                        # `@error` here would take the whole controller down with it.
                        @warn "Error reading test process output; output from this process will no longer be forwarded" testprocess_id exception=(err, catch_backtrace())
                    end
                end


                abort_accept_due_to_startup_failure_source = CancellationTokens.CancellationTokenSource()
                abort_accept_due_to_startup_failure_token = CancellationTokens.get_token(abort_accept_due_to_startup_failure_source)

                # Watch for subprocess exit before connection — if the process crashes during
                # startup (e.g. precompilation failure), close the server to unblock Sockets.accept.
                connection_established = Ref(false)
                @async try
                    wait(jl_process)
                    # Record how the process ended the moment it does, on every path. The
                    # exit code used to be captured only when the pipe read *errored*
                    # (`TestProcessIOErrorMsg`); a clean `exit(66)` from a memory recycle
                    # usually reads as plain EOF instead, so it reached the terminated
                    # handler with no exit code, was not recognised as a recycle, and fell
                    # into the crash path. Which of the two happened was a race — it flipped
                    # between the first and second recycle in one run — hence CI-only hangs.
                    ps.last_exit_code = jl_process.exitcode
                    ps.last_term_signal = jl_process.termsignal
                    if !connection_established[]
                        if CancellationTokens.is_cancellation_requested(token)
                            @debug "Test process exited before connecting (cancellation requested)" testprocess_id exitcode=jl_process.exitcode pipe_name
                        else
                            CancellationTokens.cancel(abort_accept_due_to_startup_failure_source)
                        end                        
                    end
                catch err
                    # Same reasoning as the output reader: losing the exit-code observation
                    # degrades the termination classification below, it does not justify
                    # killing the controller.
                    @warn "Error waiting for test process exit" testprocess_id exception=(err, catch_backtrace())
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

                                # Stamped here rather than in the dispatcher so it covers
                                # every method, including ones with no handler.
                                ps.last_message_at = time()

                                dispatch_testprocess_msg(endpoint, msg, (reactor_channel, ps))
                            end

                            # The loop only ends on cancellation, i.e. after the registration
                            # above SIGTERMed the child. Make sure it is really gone before we
                            # tell the controller so.
                            _terminate_and_wait!(jl_process, testprocess_id)
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
                if err isa TestProcessCrashException && !isempty(err.captured_output)
                    # The only record of why a process died before it could connect. It is
                    # dropped on the floor below, where all that survives is an exit code,
                    # so surface it here while we still have it.
                    @warn "Test process crashed during startup" testprocess_id exitcode=err.exitcode termsignal=err.termsignal output=err.captured_output
                end

                if !(err isa CancellationTokens.OperationCanceledException)
                    # A pipe error is very often the *worker* closing its end because it is
                    # exiting on its own — a memory recycle's `exit(66)`, say. Killing it
                    # here raced that exit: on a fast machine the process was already gone
                    # and the kill was a no-op, but on a slow runner it landed while the
                    # worker was still inside `exit`, and the process died with SIGTERM
                    # (signal 15) instead of its own exit code. The controller then read a
                    # deliberate recycle as a crash. Only kill a process that is still
                    # running *and* has not begun to exit; give a self-exiting one a moment
                    # to finish reporting how it ended.
                    if process_running(jl_process)
                        _wait_for_self_exit(jl_process, 5.0)
                    end
                    # SIGTERM, then SIGKILL if it sits through that, then wait: a wedged child
                    # must not leave the controller believing a process is alive that will
                    # never report, nor forgetting one that is still running.
                    _terminate_and_wait!(jl_process, testprocess_id)
                    put!(reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal, jl_process.exitcode, jl_process.termsignal))
                else
                    _terminate_and_wait!(jl_process, testprocess_id)
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
        # The controller reads this while the process is still alive (from the timeout
        # handler); once it is gone the file has no further use.
        try rm(diagnostics_file, force=true) catch end
    end

end
