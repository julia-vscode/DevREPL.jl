# Shutdown normally completes as soon as every process has reported its termination — a
# few hundred milliseconds. This is the backstop for the case where one never does.
const DEFAULT_SHUTDOWN_GRACE_SECONDS = 30.0

# Activating an environment normally takes seconds. When it takes minutes it is because the
# test process is precompiling, or fetching, or wedged — and until it answers, the controller
# has nothing to say beyond the "Activating" status it posted at the start. This is how often
# it says so anyway.
const DEFAULT_ACTIVATION_PROGRESS_SECONDS = 120.0

"""
    TestItemController(callbacks; error_handler_file=nothing, crash_reporting_pipename=nothing, log_level=:Info)

Create a test item controller that manages Julia child processes and schedules
test runs.

After construction, call `run(controller)` (or `@async run(controller)`) to start
the reactor event loop, then use [`execute_testrun`](@ref) to submit work.

# Arguments
- `callbacks::ControllerCallbacks` — callback functions invoked on test-item and process lifecycle events.

# Keyword arguments
- `error_handler_file` — optional path to a Julia file loaded in child processes for custom error handling.
- `crash_reporting_pipename` — optional named-pipe path for crash diagnostics.
- `log_level::Symbol` — minimum log level (default `:Info`).
- `schedule::Symbol` — how test items are distributed over processes (default `:duration`).
  `:duration` uses the failures-first, duration- and setup-aware model in
  [`schedule_testitems`](@ref), falling back to contiguous chunking on the first run of a
  session, when there is no history to work from. `:contiguous` always chunks, which is
  the behaviour of releases before this option existed.
- `shutdown_grace_seconds::Real` — how long [`shutdown`](@ref) waits for every test process
  to report its termination before force-killing whatever is left and stopping anyway
  (default 30). Shutdown normally completes well within a second; this only bounds the
  failure case.
- `activation_progress_seconds::Real` — how often a still-unfinished environment activation
  is reported with a warning (default 120). Activation covers the test process's own
  precompilation, so a slow one is normal and is not interrupted; this only makes it visible
  while it is happening instead of only in the post-mortem of whatever kills the run.

# Lifecycle

1. Construct: `ctrl = TestItemController(callbacks)`
2. Start reactor: `t = @async run(ctrl)`
3. Run tests: `coverage = execute_testrun(ctrl, ...)`  (blocks until done)
4. Shut down: `shutdown(ctrl); wait_for_shutdown(ctrl, t)`

See also [`ControllerCallbacks`](@ref), [`execute_testrun`](@ref), [`shutdown`](@ref),
[`wait_for_shutdown`](@ref).
"""
mutable struct TestItemController{CB<:ControllerCallbacks}
    callbacks::CB

    reactor_channel::Channel{ReactorMessage}

    test_processes::Dict{String,TestProcessState}       # flat lookup by process ID
    process_pool::Dict{ProcessEnv,Vector{String}}        # pool of process IDs by env
    test_runs::Dict{String,TestRunState}

    testprocess_precompile_not_required::Set{
        @NamedTuple{
            julia_cmd::String,
            julia_args::Vector{String},
            env::Dict{String,Union{String,Nothing}},
            coverage::Bool,
            check_bounds::String
        }
    }

    precompiled_envs::Set{ProcessEnv}

    julia_version_cache::Dict{Tuple{String,Vector{String}},VersionNumber}

    error_handler_file::Union{Nothing,String}
    crash_reporting_pipename::Union{Nothing,String}

    log_level::Symbol
    controller_fsm::FSM{ControllerPhase}

    # How long a shutdown waits for every process to report its termination before it
    # force-kills whatever is left and stops anyway. See `handle!(::ShutdownDeadlineMsg)`.
    shutdown_grace_seconds::Float64
    shutdown_timer::Union{Nothing,Timer}

    # How often `_activate_env!` warns that an activation it is still waiting on has not
    # finished.
    activation_progress_seconds::Float64

    # Scheduling history, in memory and keyed by the (stable) test item id. It survives
    # across the test runs of one session; nothing is persisted to disk.
    schedule::Symbol
    last_status::Dict{String,Symbol}
    last_duration::Dict{String,Float64}                 # milliseconds
    setup_cost::Dict{Tuple{String,String},Float64}      # (package_uri, setup name) → milliseconds

    function TestItemController(
        callbacks::CB;
        error_handler_file=nothing,
        crash_reporting_pipename=nothing,
        log_level::Symbol=:Info,
        schedule::Symbol=:duration,
        shutdown_grace_seconds::Real=DEFAULT_SHUTDOWN_GRACE_SECONDS,
        activation_progress_seconds::Real=DEFAULT_ACTIVATION_PROGRESS_SECONDS) where {CB<:ControllerCallbacks}

        schedule in (:duration, :contiguous) ||
            throw(ArgumentError("schedule must be :duration or :contiguous, got $(repr(schedule))"))
        shutdown_grace_seconds > 0 ||
            throw(ArgumentError("shutdown_grace_seconds must be positive, got $(shutdown_grace_seconds)"))
        activation_progress_seconds > 0 ||
            throw(ArgumentError("activation_progress_seconds must be positive, got $(activation_progress_seconds)"))

        return new{CB}(
            callbacks,
            Channel{ReactorMessage}(Inf),
            Dict{String,TestProcessState}(),
            Dict{ProcessEnv,Vector{String}}(),
            Dict{String,TestRunState}(),
            Set{@NamedTuple{julia_cmd::String,julia_args::Vector{String},env::Dict{String,Union{String,Nothing}},coverage::Bool,check_bounds::String}}(),
            Set{ProcessEnv}(),
            Dict{Tuple{String,Vector{String}},VersionNumber}(),
            error_handler_file,
            crash_reporting_pipename,
            log_level,
            controller_fsm("controller"),
            Float64(shutdown_grace_seconds),
            nothing,
            Float64(activation_progress_seconds),
            schedule,
            Dict{String,Symbol}(),
            Dict{String,Float64}(),
            Dict{Tuple{String,String},Float64}(),
        )
    end
end

"""
    shutdown(controller::TestItemController)

Request an orderly shutdown of the controller. Active test runs are cancelled,
all child processes are terminated, and the reactor loop exits.

This function returns immediately. Use [`wait_for_shutdown`](@ref) to block
until all resources are fully released.

The reactor stops as soon as every child process has reported its termination. Should
one fail to within `shutdown_grace_seconds` (a [`TestItemController`](@ref) keyword,
default 30 s), whatever is left is force-killed and dropped, so the reactor loop is
guaranteed to exit.
"""
function shutdown(controller::TestItemController)
    @info "Queueing controller shutdown"
    put!(controller.reactor_channel, ShutdownMsg())
end

"""
    wait_for_shutdown(controller)

Block until the reactor loop has exited and all process IO tasks have completed.
Call this after `shutdown(controller)` when you need to guarantee that all
background tasks and IO handles are fully closed (e.g. during precompilation).
"""
function wait_for_shutdown(controller::TestItemController, reactor_task::Task)
    # Wait for the reactor loop to finish processing all shutdown messages
    @debug "Now waiting for reactor task to finish"
    try wait(reactor_task) catch end
    # Wait for all process IO tasks to finish their cleanup
    @debug "Now waiting for process IO tasks to finish"
    for ps in values(controller.test_processes)
        for t in ps.process_tasks
            try wait(t) catch end
        end
    end
    @debug "Finished waiting for shutdown"
end

"""
    terminate_test_process(controller::TestItemController, id::String)

Request termination of a single test process by its `id`. The process is killed
asynchronously; the `on_process_terminated` callback fires when it is gone.
"""
function terminate_test_process(controller::TestItemController, id::String)
    @debug "Terminating test process" id
    put!(controller.reactor_channel, TerminateTestProcessMsg(id))
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════════
# Reactor event loop
# ═══════════════════════════════════════════════════════════════════════════════

function Base.run(controller::TestItemController)
    while true
        msg = take!(controller.reactor_channel)
        @debug "Reactor msg" msg_type=typeof(msg).name.name

        should_stop = handle!(controller, msg)
        should_stop === true && break
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Controller-level handlers
# ═══════════════════════════════════════════════════════════════════════════════

function handle!(c::TestItemController, ::ShutdownMsg)
    # Idempotent. A second shutdown request must be a no-op, not an FSM error: this runs on
    # the reactor, and an exception here does not fail anything visibly — it kills the
    # reactor loop, and every run in flight then hangs until its caller times out. That is
    # precisely how a test-harness timeout that called `shutdown` twice turned a slow run
    # into a wedged controller.
    if state(c.controller_fsm) != ControllerRunning
        @debug "Ignoring shutdown request; controller already $(state(c.controller_fsm))"
        return state(c.controller_fsm) == ControllerStopped
    end

    @info "Shutting down controller, terminating $(length(c.test_processes)) test process(es)"
    transition!(c.controller_fsm, ControllerShuttingDown; reason="shutdown requested")

    # Cancel all active test runs and signal completion
    for (trid, tr) in c.test_runs
        if state(tr.fsm) ∉ (TestRunCancelled, TestRunCompleted)
            CancellationTokens.cancel(tr.cancellation_source)
            for ((testitem_id, test_env_id), _) in tr.remaining_work
                push!(tr.reported_items, testitem_id)
                _notify_testitem_skipped(c.callbacks, trid, testitem_id, test_env_id)
            end
            transition!(tr.fsm, TestRunCancelled; reason="shutdown")
            _signal_testrun_completion!(tr, nothing)
        end
    end

    # Shutdown all processes
    for (pid, ps) in c.test_processes
        if state(ps.fsm) != ProcessDead
            _shutdown_test_process!(c, ps)
        end
    end

    if isempty(c.test_processes)
        _controller_stopped!(c; reason="no processes to drain")
        return true  # break reactor loop
    end

    # From here the reactor only stops once every remaining process has posted a
    # `TestProcessTerminatedMsg`. Bound that wait: if any process never reports — its IO task
    # wedged, its child ignores SIGTERM, whatever — the deadline handler force-kills and
    # drops what is left. Without this a single stuck worker keeps `run(controller)` from
    # ever returning, and every caller waiting on it hangs with it.
    grace = c.shutdown_grace_seconds
    reactor_channel = c.reactor_channel
    c.shutdown_timer = Timer(grace) do _
        put!(reactor_channel, ShutdownDeadlineMsg())
    end
    return false
end

function _controller_stopped!(c::TestItemController; reason::String)
    if c.shutdown_timer !== nothing
        try close(c.shutdown_timer) catch end
        c.shutdown_timer = nothing
    end
    transition!(c.controller_fsm, ControllerStopped; reason=reason)
    return nothing
end

function handle!(c::TestItemController, ::ShutdownDeadlineMsg)
    c.shutdown_timer = nothing
    if state(c.controller_fsm) != ControllerShuttingDown
        # Already stopped normally (the timer raced the last termination), or never shutting
        # down at all; either way there is nothing to force.
        return state(c.controller_fsm) == ControllerStopped
    end

    remaining = collect(values(c.test_processes))
    @warn "Shutdown did not complete within $(c.shutdown_grace_seconds)s; force-terminating $(length(remaining)) test process(es)" processes=[(id=ps.id, state=string(state(ps.fsm))) for ps in remaining]

    for ps in remaining
        _force_terminate_process!(c, ps; reason="shutdown deadline")
    end

    _controller_stopped!(c; reason="shutdown deadline")
    return true  # break reactor loop
end

# The unconditional counterpart of the normal termination path: no waiting for the process
# IO task, no message round-trip. Kills the child outright (SIGKILL where that exists —
# plain `kill` already SIGTERMed it on the normal path and it evidently did not go), drops
# every registration and forgets the process. Only for when the cooperative path has failed.
function _force_terminate_process!(c::TestItemController, ps::TestProcessState; reason::String)
    jl_process = ps.jl_process
    if jl_process !== nothing && process_running(jl_process)
        try
            @static if Sys.iswindows()
                kill(jl_process)
            else
                kill(jl_process, Base.SIGKILL)
            end
        catch
        end
    end

    for reg in (ps.termination_reg, ps.testrun_watcher_registration, ps.timeout_reg)
        reg === nothing || (try close(reg) catch end)
    end
    ps.termination_reg = nothing
    ps.testrun_watcher_registration = nothing
    ps.timeout_reg = nothing
    if ps.timeout_cs !== nothing
        try CancellationTokens.cancel(ps.timeout_cs) catch end
        ps.timeout_cs = nothing
    end
    ps.jl_process = nothing
    ps.endpoint = nothing

    if state(ps.fsm) != ProcessDead
        transition!(ps.fsm, ProcessDead; reason=reason)
    end

    pool_ids = get(c.process_pool, ps.env, String[])
    idx = findfirst(isequal(ps.id), pool_ids)
    idx === nothing || deleteat!(pool_ids, idx)
    delete!(c.test_processes, ps.id)

    if c.callbacks.on_process_terminated !== nothing
        c.callbacks.on_process_terminated(ps.id)
    end
    return nothing
end

function handle!(c::TestItemController, msg::TestProcessStatusChangedMsg)
    @debug "Forwarding test process status change" id=msg.testprocess_id status=msg.status
    if c.callbacks.on_process_status_changed !== nothing
        c.callbacks.on_process_status_changed(msg.testprocess_id, msg.status)
    end
    return false
end

function handle!(c::TestItemController, msg::TestProcessOutputMsg)
    @debug "Forwarding test process output" id=msg.testprocess_id ncodeunits=ncodeunits(msg.output)
    if c.callbacks.on_process_output !== nothing
        c.callbacks.on_process_output(msg.testprocess_id, msg.output)
    end
    return false
end

function handle!(c::TestItemController, msg::TerminateTestProcessMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        @debug "Ignoring terminate request for unknown process" testprocess_id=msg.testprocess_id
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) == ProcessDead
        @debug "Ignoring terminate request for already-dead process" testprocess_id=msg.testprocess_id
        return false
    end

    @info "Terminating test process '$(msg.testprocess_id)' via request"
    # Tag the process so the merged TestProcessTerminatedMsg posted by start()
    # when it exits will carry skip_remaining=true (this is a user-requested
    # termination, so remaining items must not be redistributed).
    ps.skip_remaining_on_termination = true
    _kill_julia_process!(ps)

    return false
end

function handle!(c::TestItemController, msg::TestProcessTerminatedMsg)
    @info "Test process '$(msg.testprocess_id)' terminated"

    # Make sure the exit code is known before anything below classifies this termination.
    # The process watcher records it asynchronously and normally wins, but this message can
    # be posted from the pipe reader the instant it hits EOF — and telling a memory-recycle
    # `exit(66)` from a crash depends on the code being here. Read it straight off the
    # process object as the fallback; the OS has reaped the child by the time its pipe has
    # closed, so it is available without waiting.
    if haskey(c.test_processes, msg.testprocess_id)
        ps = c.test_processes[msg.testprocess_id]
        if ps.last_exit_code === nothing && ps.jl_process !== nothing && !process_running(ps.jl_process)
            ps.last_exit_code = ps.jl_process.exitcode
            ps.last_term_signal = ps.jl_process.termsignal
        end
    end

    # Run-level redistribution must happen BEFORE pool cleanup below, because
    # the redistribution logic still needs ps state (current_testitem_id,
    # has_started_items, fsm state, last_exit_code, ...) which lives in
    # c.test_processes[msg.testprocess_id].
    if msg.testrun_id !== nothing
        _handle_termination_during_run!(c, msg)
    end

    if haskey(c.test_processes, msg.testprocess_id)
        ps = c.test_processes[msg.testprocess_id]
        if state(ps.fsm) != ProcessDead
            transition!(ps.fsm, ProcessDead; reason="terminated")
        end

        if ps.termination_reg !== nothing
            try close(ps.termination_reg) catch end
            ps.termination_reg = nothing
        end
        if ps.testrun_watcher_registration !== nothing
            try close(ps.testrun_watcher_registration) catch end
            ps.testrun_watcher_registration = nothing
        end

        # Remove from pool
        pool_ids = get(c.process_pool, ps.env, String[])
        idx = findfirst(isequal(msg.testprocess_id), pool_ids)
        if idx !== nothing
            deleteat!(pool_ids, idx)
        end

        delete!(c.test_processes, msg.testprocess_id)

        if c.callbacks.on_process_terminated !== nothing
            c.callbacks.on_process_terminated(msg.testprocess_id)
        end
    end

    # If shutting down and all processes gone, transition to stopped
    if state(c.controller_fsm) == ControllerShuttingDown && isempty(c.test_processes)
        _controller_stopped!(c; reason="all processes terminated")
        return true  # break reactor loop
    end
    return false
end

function handle!(c::TestItemController, msg::ReturnToPoolMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        @debug "Ignoring return_to_pool for unknown process" id=msg.testprocess_id
        return false
    end
    ps = c.test_processes[msg.testprocess_id]
    if state(ps.fsm) == ProcessIdle
        @debug "Ignoring duplicate return_to_pool" id=msg.testprocess_id
        return false
    end

    # Coverage results must not depend on how warm the process is. On a reused process the
    # compiler already holds inference results for the code under test, so pure calls with
    # constant arguments are folded away instead of executed and their line counters never
    # move again: julia-vscode#3707 reported the same unchanged test item at 100% on the
    # first run and 27.27% on every later run against the same process. A coverage process
    # is therefore retired at the end of its test run instead of being pooled, which is also
    # what `Pkg.test(coverage=true)` effectively does.
    if ps.env.mode == "Coverage"
        @info "Test process '$(msg.testprocess_id)' finished its coverage test run, terminating it instead of pooling"
        _clear_testrun_on_process!(ps)
        _shutdown_test_process!(c, ps)
        return false
    end

    @info "Test process '$(msg.testprocess_id)' finished its test run, returning to pool"
    _clear_testrun_on_process!(ps)

    if state(ps.fsm) == ProcessStarting
        # Process is still starting up; testrun cleared, it will transition to Idle
        # when TestProcessLaunchedMsg arrives and sees testrun_id is null
        @debug "Cleared testrun metadata while process is still starting" id=msg.testprocess_id
    elseif state(ps.fsm) != ProcessDead
        transition!(ps.fsm, ProcessIdle; reason="returned to pool")
    end

    if c.callbacks.on_process_status_changed !== nothing
        c.callbacks.on_process_status_changed(msg.testprocess_id, "Idle")
    end

    # If shutting down, immediately terminate the returned process
    if state(c.controller_fsm) == ControllerShuttingDown
        _shutdown_test_process!(c, ps)
    end
    return false
end

function handle!(c::TestItemController, msg::GetProcsForTestRunMsg)
    # Guard: reject new test runs during shutdown
    if state(c.controller_fsm) != ControllerRunning
        @warn "Rejecting test run request during shutdown" testrun_id=msg.testrun_id
        if haskey(c.test_runs, msg.testrun_id)
            tr = c.test_runs[msg.testrun_id]
            CancellationTokens.cancel(tr.cancellation_source)
        end
        return false
    end

    # A run can be cancelled (and, once its completion is signalled, deleted) before this
    # message is handled: a token that is already cancelled when `execute_testrun` registers
    # its bridge posts `TestRunCancelledMsg` ahead of this request. Launching processes for
    # it would leak them and index a run that is gone.
    if !haskey(c.test_runs, msg.testrun_id) || state(c.test_runs[msg.testrun_id].fsm) == TestRunCancelled
        @debug "Ignoring GetProcsForTestRunMsg for cancelled or unknown test run" testrun_id=msg.testrun_id
        return false
    end

    @debug "Acquiring test processes for test run" testrun_id=msg.testrun_id env_count=length(msg.proc_count_by_env)

    our_procs = Dict{ProcessEnv,Vector{String}}()

    for (k, v) in pairs(msg.proc_count_by_env)
        our_procs[k] = String[]

        pool_ids = get!(c.process_pool, k) do
            String[]
        end

        # Find idle processes in pool
        existing_idle_ids = filter(pool_ids) do pid
            haskey(c.test_processes, pid) && state(c.test_processes[pid].fsm) == ProcessIdle
        end

        env_str = join(("  $ek = $ev" for (ek, ev) in k.env), "\n")
        @info "Test environment\n\nProject Uri: $(k.project_uri)\nPackage Uri: $(k.package_uri)\nPackage Name: $(k.package_name)\nJulia command: $(k.juliaCmd)\nJulia args: $(k.juliaArgs)\nJulia Num Threads: $(k.juliaNumThreads)\nMode: $(k.mode)\nEnv:\n$env_str\n\nWe need $v procs, there are $(length(pool_ids)) processes, of which $(length(existing_idle_ids)) are idle."

        # Grab existing idle procs
        for pid in Iterators.take(existing_idle_ids, v)
            ps = c.test_processes[pid]
            @info "Reusing idle test process '$(pid)' for package '$(k.package_name)'"

            testrun_token = haskey(c.test_runs, msg.testrun_id) ?
                CancellationTokens.get_token(c.test_runs[msg.testrun_id].cancellation_source) : nothing

            _setup_testrun_on_process!(ps, msg.testrun_id, msg.test_setups, msg.coverage_root_uris, msg.log_level, testrun_token)

            transition!(ps.fsm, ProcessReviseOrStart; reason="reused for testrun")

            env_hash = get(msg.env_content_hash_by_env, k, nothing)

            if ps.endpoint === nothing || env_hash != ps.test_env_content_hash
                # No endpoint or hash changed — need full restart
                @debug "Restarting process (no endpoint or env hash changed)" testprocess_id=pid
                tr = haskey(c.test_runs, msg.testrun_id) ? c.test_runs[msg.testrun_id] : nothing
                replacement_ps, _ = _replace_process_state!(
                    c,
                    ps;
                    tr=tr,
                    test_env_content_hash=env_hash,
                    is_precompile_process=ps.is_precompile_process,
                    precompile_done=ps.precompile_done,
                    preserve_testrun=true,
                )
                transition!(replacement_ps.fsm, ProcessStarting; reason="restart needed")
                _launch_julia_process!(c, replacement_ps)
                push!(our_procs[k], replacement_ps.id)
                if c.callbacks.on_process_created !== nothing
                    tr_for_cb = c.test_runs[msg.testrun_id]
                    c.callbacks.on_process_created(replacement_ps.id, _resolve_test_env_id(tr_for_cb, k))
                end
            else
                # Try revise
                transition!(ps.fsm, ProcessRevising; reason="revising")
                put!(c.reactor_channel, TestProcessStatusChangedMsg(pid, "Revising"))
                _start_revise!(c, ps, env_hash)
                push!(our_procs[k], pid)
            end
        end

        # Pre-1.10 Julia version precompile hack
        if !(
            (
                julia_cmd=k.juliaCmd,
                julia_args=k.juliaArgs,
                env=k.env,
                coverage=k.mode == "Coverage",
                check_bounds=k.check_bounds
            ) in c.testprocess_precompile_not_required)

            @debug "Checking whether test environment precompilation is needed"
            coverage_arg = k.mode == "Coverage" ? "--code-coverage=user" : "--code-coverage=none"

            jlEnv = _subprocess_env(k)

            julia_version = _resolve_julia_version(c, k)

            if julia_version !== nothing && julia_version <= v"1.10.0"
                testserver_precompile_script = joinpath(@__DIR__, "../testprocess/app/testserver_precompile.jl")

                # "auto" is Julia's default and rejected as a flag value before 1.8 — only
                # pass --check-bounds when overriding (matches the test process launch).
                check_bounds_args = k.check_bounds == "auto" ? String[] : ["--check-bounds=$(k.check_bounds)"]
                precompile_success = success(Cmd(`$(k.juliaCmd) $(k.juliaArgs) $(check_bounds_args) --startup-file=no --history-file=no --depwarn=no $coverage_arg $testserver_precompile_script`, detach=false, env=jlEnv))

                @debug "Precompile of test server" precompile_success
            end

            push!(c.testprocess_precompile_not_required, (
                julia_cmd=k.juliaCmd,
                julia_args=k.juliaArgs,
                env=k.env,
                coverage=k.mode == "Coverage",
                check_bounds=k.check_bounds
            ))
        end

        precompile_required = !(k in c.precompiled_envs)
        identified_precompile_proc = false

        while length(our_procs[k]) < v
            @info "Launching new test process for package '$(k.package_name)'"

            this_is_the_precompile_proc = precompile_required && !identified_precompile_proc
            identified_precompile_proc = true

            env_hash = get(msg.env_content_hash_by_env, k, nothing)
            testprocess_id = string(UUIDs.uuid4())

            # Create TestProcessState and register it
            ps = TestProcessState(testprocess_id, k;
                is_precompile_process=this_is_the_precompile_proc,
                precompile_done=!precompile_required,
                test_env_content_hash=env_hash)
            c.test_processes[testprocess_id] = ps

            push!(pool_ids, testprocess_id)

            testrun_token = haskey(c.test_runs, msg.testrun_id) ?
                CancellationTokens.get_token(c.test_runs[msg.testrun_id].cancellation_source) : nothing

            _setup_testrun_on_process!(ps, msg.testrun_id, msg.test_setups, msg.coverage_root_uris, msg.log_level, testrun_token)

            transition!(ps.fsm, ProcessStarting; reason="new process")
            _launch_julia_process!(c, ps)

            push!(our_procs[k], testprocess_id)

            if c.callbacks.on_process_created !== nothing
                tr = c.test_runs[msg.testrun_id]
                c.callbacks.on_process_created(testprocess_id, _resolve_test_env_id(tr, k))
            end
        end
    end

    @info "Sending $(sum(length, values(our_procs), init=0)) test process(es) to test run '$(msg.testrun_id)'"
    put!(
        c.reactor_channel,
        ProcsAcquiredMsg(msg.testrun_id, our_procs)
    )
    return false
end

# ═══════════════════════════════════════════════════════════════════════════════
# Test-run handlers
# ═══════════════════════════════════════════════════════════════════════════════

function handle!(c::TestItemController, msg::ProcsAcquiredMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        @debug "Ignoring ProcsAcquiredMsg for unknown test run" testrun_id=msg.testrun_id
        return false
    end
    tr = c.test_runs[msg.testrun_id]

    if state(tr.fsm) == TestRunCancelled
        # Cancellation arrived before process acquisition completed.
        @info "Returning $(sum(length, values(msg.procs), init=0)) process(es) to pool after deferred cancellation"
        for pid in Iterators.flatten(values(msg.procs))
            if haskey(c.test_processes, pid)
                ps = c.test_processes[pid]
                put!(c.reactor_channel, ReturnToPoolMsg(pid, ps.env))
            end
        end
        return false
    end

    transition!(tr.fsm, TestRunProcsAcquired; reason="procs acquired")
    tr.procs = msg.procs

    @info "Acquired $(sum(length, values(msg.procs), init=0)) test process(es) for test run"

    # Distribute test items over test processes — see src/scheduling.jl
    for (env, proc_ids) in pairs(msg.procs)
        _assign_items_to_procs!(c, tr, env, proc_ids)
    end

    # Dispatch buffered ready notifications
    for pid in tr.processes_ready_before_acquired
        if haskey(tr.testitem_ids_by_proc, pid) && haskey(c.test_processes, pid)
            ps = c.test_processes[pid]
            items_for_proc = _items_for(tr, _resolve_test_env_id(tr, ps.env), tr.testitem_ids_by_proc[pid])
            @debug "Dispatching buffered test items to ready process" testrun_id=msg.testrun_id process_id=pid assigned=length(items_for_proc)
            if state(ps.fsm) == ProcessReadyToRun
                transition!(ps.fsm, ProcessRunning; reason="dispatching buffered items")
            end
            _send_run_testitems!(c, ps, items_for_proc)
            push!(tr.items_dispatched_to_procs, pid)
        end
    end

    return false
end

function handle!(c::TestItemController, msg::TestRunCancelledMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]

    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    @info "Test run cancelled, skipping $(length(tr.remaining_work)) remaining work unit(s)"

    if state(tr.fsm) == TestRunWaitingForProcs
        transition!(tr.fsm, TestRunCancelled; reason="cancelled before procs acquired")
    elseif state(tr.fsm) in (TestRunProcsAcquired, TestRunRunning)
        transition!(tr.fsm, TestRunCancelled; reason="cancelled")
    else
        transition!(tr.fsm, TestRunCancelled; reason="cancelled from $(state(tr.fsm))")
    end

    CancellationTokens.cancel(tr.cancellation_source)

    # Report all remaining test items as skipped
    for ((testitem_id, test_env_id), _) in tr.remaining_work
        push!(tr.reported_items, testitem_id)
        _notify_testitem_skipped(c.callbacks, msg.testrun_id, testitem_id, test_env_id)
    end
    empty!(tr.remaining_work)

    # Terminate all Julia processes assigned to this cancelled run.
    if tr.procs !== nothing
        for pid in Iterators.flatten(values(tr.procs))
            if haskey(c.test_processes, pid)
                ps = c.test_processes[pid]
                _shutdown_test_process!(c, ps)
            end
        end
    end

    # Signal completion
    _signal_testrun_completion!(tr, nothing)
    return false
end

function handle!(c::TestItemController, msg::ReadyToRunTestItemsMsg)
    if !haskey(c.test_runs, msg.testrun_id) || !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    ps = c.test_processes[msg.testprocess_id]

    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    if state(tr.fsm) == TestRunProcsAcquired || state(tr.fsm) == TestRunRunning
        @info "Test process '$(msg.testprocess_id)' is ready, dispatching test items"
        assigned_ids = get(tr.testitem_ids_by_proc, msg.testprocess_id, String[])
        env_id = _resolve_test_env_id(tr, ps.env)
        items_for_proc = _items_for(tr, env_id, assigned_ids)
        @debug "Dispatch lookup" testprocess_id=msg.testprocess_id env_id assigned=length(assigned_ids) found=length(items_for_proc)
        if state(ps.fsm) == ProcessReadyToRun
            transition!(ps.fsm, ProcessRunning; reason="dispatching items")
        end
        _send_run_testitems!(c, ps, items_for_proc)
        push!(tr.items_dispatched_to_procs, msg.testprocess_id)
    elseif state(tr.fsm) == TestRunWaitingForProcs
        @info "Test process '$(msg.testprocess_id)' is ready, waiting for process acquisition to finish"
        push!(tr.processes_ready_before_acquired, msg.testprocess_id)
    end
    return false
end

function handle!(c::TestItemController, msg::PrecompileDoneMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]

    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    @info "Test process '$(msg.testprocess_id)' completed precompilation for package '$(msg.env.package_name)'"
    push!(c.precompiled_envs, msg.env)

    # Notify peer processes that are waiting for precompile
    if tr.procs !== nothing && haskey(tr.procs, msg.env)
        for pid in tr.procs[msg.env]
            if pid != msg.testprocess_id && haskey(c.test_processes, pid)
                ps = c.test_processes[pid]
                ps.precompile_done = true
                if state(ps.fsm) == ProcessWaitingForPrecompile
                    @debug "Peer process completed precompile, activating" testprocess_id=pid
                    transition!(ps.fsm, ProcessActivatingEnv; reason="precompile_by_other_proc_done")
                    _activate_env!(c, ps)
                end
            end
        end
    end
    return false
end

function handle!(c::TestItemController, msg::AttachDebuggerMsg)
    c.callbacks.on_attach_debugger(msg.testrun_id, msg.debug_pipe_name)
    return false
end

function handle!(c::TestItemController, msg::TestItemStartedMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    if state(tr.fsm) == TestRunProcsAcquired
        transition!(tr.fsm, TestRunRunning; reason="first test item started")
    end

    # Resolve test_env_id from the process's env
    test_env_id = if haskey(c.test_processes, msg.testprocess_id)
        _resolve_test_env_id(tr, c.test_processes[msg.testprocess_id].env)
    else
        first(tr.test_environments).id
    end

    # A speculatively stolen item can be running on two processes at once. Only the owner
    # may report on it — see `_owns_testitem`. The process really is executing something,
    # so `has_started_items` is still set, but we neither report the start nor make this
    # process the item's timeout/crash victim.
    if !_owns_testitem(tr, msg.testprocess_id, msg.testitem_id)
        @info "Ignoring start of test item '$(msg.testitem_id)' from test process '$(msg.testprocess_id)', which no longer owns it (duplicate execution after a steal)"
        if haskey(c.test_processes, msg.testprocess_id)
            c.test_processes[msg.testprocess_id].has_started_items = true
        end
        return false
    end

    c.callbacks.on_testitem_started(msg.testrun_id, msg.testitem_id, test_env_id)
    _record_testitem_started!(c, msg.testitem_id)

    # Start timeout if work unit has one
    if haskey(c.test_processes, msg.testprocess_id)
        ps = c.test_processes[msg.testprocess_id]
        ps.current_testitem_id = msg.testitem_id
        ps.current_testitem_started_at = time()
        ps.has_started_items = true

        work_key = (msg.testitem_id, test_env_id)
        wu = get(tr.remaining_work, work_key, nothing)
        timeout = wu !== nothing ? wu.timeout : nothing

        if timeout !== nothing
            # The test process's watchdog fires at the item's real deadline; we wait a grace
            # period beyond it so its diagnostic dump is on disk before we kill the process.
            # The item is still reported as having timed out after `timeout` seconds.
            ps.timeout_cs = CancellationTokens.CancellationTokenSource(timeout + WATCHDOG_KILL_GRACE_SECONDS)
            ps.timeout_reg = CancellationTokens.register(CancellationTokens.get_token(ps.timeout_cs)) do
                try
                    put!(c.reactor_channel, TestItemTimeoutMsg(msg.testrun_id, msg.testprocess_id, msg.testitem_id))
                catch
                end
            end
        end
    end
    return false
end

function _cancel_timeout!(ps::TestProcessState)
    if ps.timeout_cs !== nothing
        CancellationTokens.cancel(ps.timeout_cs)
        ps.timeout_cs = nothing
    end
    if ps.timeout_reg !== nothing
        try close(ps.timeout_reg) catch end
        ps.timeout_reg = nothing
    end
    ps.current_testitem_id = nothing
    ps.current_testitem_started_at = nothing
end

function handle!(c::TestItemController, msg::TestItemPassedMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    # Cancel timeout
    if haskey(c.test_processes, msg.testprocess_id)
        _cancel_timeout!(c.test_processes[msg.testprocess_id])
    end

    # Handle stolen tracking
    stolen_idx = findfirst(isequal(msg.testitem_id), get(tr.stolen_ids_by_proc, msg.testprocess_id, String[]))
    if stolen_idx !== nothing
        deleteat!(tr.stolen_ids_by_proc[msg.testprocess_id], stolen_idx)
    end

    # Discard the result if another process owns this item — see `_owns_testitem`. The
    # timeout was cancelled above, which matters: a process can lose ownership *after*
    # arming one. Stealing still runs, because this process is now idle and needs work.
    if !_owns_testitem(tr, msg.testprocess_id, msg.testitem_id)
        _log_discarded_result(msg.testitem_id, msg.testprocess_id, "passed")
        _check_stealing!(c, tr, msg.testprocess_id)
        _check_testrun_complete!(c, tr)
        return false
    end

    # Resolve test_env_id
    test_env_id = if haskey(c.test_processes, msg.testprocess_id)
        _resolve_test_env_id(tr, c.test_processes[msg.testprocess_id].env)
    else
        first(tr.test_environments).id
    end

    work_key = (msg.testitem_id, test_env_id)
    if haskey(tr.remaining_work, work_key)
        delete!(tr.remaining_work, work_key)
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)

        push!(tr.reported_items, msg.testitem_id)
        _notify_testitem_passed(c.callbacks, msg.testrun_id, msg.testitem_id, test_env_id, msg.duration, msg.perf)
        _record_testitem_result!(c, msg.testitem_id, :passed, msg.duration)

        if msg.coverage !== nothing
            append!(tr.coverage, map(i -> CoverageTools.FileCoverage(uri2filepath(i.uri), "", i.coverage), msg.coverage))
        end
    else
        _log_unexpected_missing_work(tr, msg.testitem_id, msg.testprocess_id, test_env_id, "passed")
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)
    end

    _check_stealing!(c, tr, msg.testprocess_id)
    _check_testrun_complete!(c, tr)
    return false
end

function _convert_stack_trace(server_stack::Union{Missing,Vector{TestItemServerProtocol.TestMessageStackFrame}})
    server_stack === missing && return nothing
    return TestMessageStackFrame[
        TestMessageStackFrame(
            frame.label,
            frame.uri === missing ? nothing : frame.uri,
            frame.location !== missing ? frame.location.position.line : nothing,
            frame.location !== missing ? frame.location.position.character : nothing,
        ) for frame in server_stack
    ]
end

function handle!(c::TestItemController, msg::TestItemFailedMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    if haskey(c.test_processes, msg.testprocess_id)
        _cancel_timeout!(c.test_processes[msg.testprocess_id])
    end

    stolen_idx = findfirst(isequal(msg.testitem_id), get(tr.stolen_ids_by_proc, msg.testprocess_id, String[]))
    if stolen_idx !== nothing
        deleteat!(tr.stolen_ids_by_proc[msg.testprocess_id], stolen_idx)
    end

    # Discard the result if another process owns this item — see `_owns_testitem`.
    if !_owns_testitem(tr, msg.testprocess_id, msg.testitem_id)
        _log_discarded_result(msg.testitem_id, msg.testprocess_id, "failed")
        _check_stealing!(c, tr, msg.testprocess_id)
        _check_testrun_complete!(c, tr)
        return false
    end

    # Resolve test_env_id
    test_env_id = if haskey(c.test_processes, msg.testprocess_id)
        _resolve_test_env_id(tr, c.test_processes[msg.testprocess_id].env)
    else
        first(tr.test_environments).id
    end

    work_key = (msg.testitem_id, test_env_id)
    if haskey(tr.remaining_work, work_key)
        delete!(tr.remaining_work, work_key)
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)

        push!(tr.reported_items, msg.testitem_id)
        _notify_testitem_failed(c.callbacks,
            msg.testrun_id,
            msg.testitem_id,
            test_env_id,
            TestMessage[
                TestMessage(
                    i.message,
                    coalesce(i.expectedOutput, nothing),
                    coalesce(i.actualOutput, nothing),
                    i.location.uri,
                    i.location.position.line,
                    i.location.position.character,
                    _convert_stack_trace(i.stackTrace),
                ) for i in msg.messages
            ],
            msg.duration,
            msg.perf
        )
        _record_testitem_result!(c, msg.testitem_id, :failed, msg.duration)
    else
        _log_unexpected_missing_work(tr, msg.testitem_id, msg.testprocess_id, test_env_id, "failed")
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)
    end

    _check_stealing!(c, tr, msg.testprocess_id)
    _check_testrun_complete!(c, tr)
    return false
end

function handle!(c::TestItemController, msg::TestItemErroredMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    if haskey(c.test_processes, msg.testprocess_id)
        _cancel_timeout!(c.test_processes[msg.testprocess_id])
    end

    stolen_idx = findfirst(isequal(msg.testitem_id), get(tr.stolen_ids_by_proc, msg.testprocess_id, String[]))
    if stolen_idx !== nothing
        deleteat!(tr.stolen_ids_by_proc[msg.testprocess_id], stolen_idx)
    end

    # Discard the result if another process owns this item — see `_owns_testitem`.
    if !_owns_testitem(tr, msg.testprocess_id, msg.testitem_id)
        _log_discarded_result(msg.testitem_id, msg.testprocess_id, "errored")
        _check_stealing!(c, tr, msg.testprocess_id)
        _check_testrun_complete!(c, tr)
        return false
    end

    # Resolve test_env_id
    test_env_id = if haskey(c.test_processes, msg.testprocess_id)
        _resolve_test_env_id(tr, c.test_processes[msg.testprocess_id].env)
    else
        first(tr.test_environments).id
    end

    work_key = (msg.testitem_id, test_env_id)
    if haskey(tr.remaining_work, work_key)
        delete!(tr.remaining_work, work_key)
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)

        push!(tr.reported_items, msg.testitem_id)
        _notify_testitem_errored(c.callbacks,
            msg.testrun_id,
            msg.testitem_id,
            test_env_id,
            TestMessage[
                TestMessage(
                    i.message,
                    nothing,
                    nothing,
                    i.location.uri,
                    i.location.position.line,
                    i.location.position.character,
                    _convert_stack_trace(i.stackTrace),
                ) for i in msg.messages
            ],
            msg.duration,
            msg.perf
        )
        _record_testitem_result!(c, msg.testitem_id, :errored, msg.duration)
    else
        _log_unexpected_missing_work(tr, msg.testitem_id, msg.testprocess_id, test_env_id, "errored")
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)
    end

    _check_stealing!(c, tr, msg.testprocess_id)
    _check_testrun_complete!(c, tr)
    return false
end

function handle!(c::TestItemController, msg::TestItemSkippedStolenMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    stolen_idx = findfirst(isequal(msg.testitem_id), get(tr.stolen_ids_by_proc, msg.testprocess_id, String[]))
    if stolen_idx !== nothing
        deleteat!(tr.stolen_ids_by_proc[msg.testprocess_id], stolen_idx)
    end

    # Cancel timeout if this item is the active one
    if haskey(c.test_processes, msg.testprocess_id)
        ps = c.test_processes[msg.testprocess_id]
        if ps.current_testitem_id == msg.testitem_id
            _cancel_timeout!(ps)
        end
    end

    _check_stealing!(c, tr, msg.testprocess_id)
    _check_testrun_complete!(c, tr)
    return false
end

function handle!(c::TestItemController, msg::TestItemSkippedMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    # Cancel timeout
    if haskey(c.test_processes, msg.testprocess_id)
        _cancel_timeout!(c.test_processes[msg.testprocess_id])
    end

    # Handle stolen tracking
    stolen_idx = findfirst(isequal(msg.testitem_id), get(tr.stolen_ids_by_proc, msg.testprocess_id, String[]))
    if stolen_idx !== nothing
        deleteat!(tr.stolen_ids_by_proc[msg.testprocess_id], stolen_idx)
    end

    # Discard the result if another process owns this item — see `_owns_testitem`.
    if !_owns_testitem(tr, msg.testprocess_id, msg.testitem_id)
        _log_discarded_result(msg.testitem_id, msg.testprocess_id, "skipped")
        _check_stealing!(c, tr, msg.testprocess_id)
        _check_testrun_complete!(c, tr)
        return false
    end

    # Resolve test_env_id
    test_env_id = if haskey(c.test_processes, msg.testprocess_id)
        _resolve_test_env_id(tr, c.test_processes[msg.testprocess_id].env)
    else
        first(tr.test_environments).id
    end

    work_key = (msg.testitem_id, test_env_id)
    if haskey(tr.remaining_work, work_key)
        delete!(tr.remaining_work, work_key)
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)

        push!(tr.reported_items, msg.testitem_id)
        _notify_testitem_skipped(c.callbacks, msg.testrun_id, msg.testitem_id, test_env_id, msg.reason)
    else
        _log_unexpected_missing_work(tr, msg.testitem_id, msg.testprocess_id, test_env_id, "skipped")
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)
    end

    _check_stealing!(c, tr, msg.testprocess_id)
    _check_testrun_complete!(c, tr)
    return false
end

# Records what a setup cost and printed on this process. The test process replays the output
# onto every item that declares the setup itself; what the controller keeps this for is the
# cost model, and it therefore survives for as long as the process caches the setup.
function handle!(c::TestItemController, msg::TestSetupEvaluatedMsg)
    key = (msg.package_uri, msg.name)

    # Per-process, and only while the process is still around to have the setup cached.
    ps = get(c.test_processes, msg.testprocess_id, nothing)
    if ps !== nothing
        ps.loaded_setups[key] = (output=msg.output, duration=msg.duration)
    end

    # Controller-wide, and deliberately outside the branch above: what a setup costs is a
    # property of the setup, not of whichever process happened to report it, so it is worth
    # keeping even when that process has already been recycled or terminated. It feeds the
    # scheduler's affinity model, which prices duplicating a setup across processes against
    # the imbalance that relieves.
    if msg.duration !== nothing
        c.setup_cost[key] = msg.duration
    end

    return false
end

function handle!(c::TestItemController, msg::AppendOutputMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    test_env_id = if haskey(c.test_processes, msg.testprocess_id)
        _resolve_test_env_id(tr, c.test_processes[msg.testprocess_id].env)
    else
        first(tr.test_environments).id
    end
    c.callbacks.on_append_output(msg.testrun_id, msg.testitem_id, test_env_id, msg.output)
    return false
end

# Run-level half of the merged TestProcessTerminatedMsg handler: redistribute
# any un-started items the dead process still owned, or error/skip them according
# to context (user-requested termination, controller shutdown, startup crash,
# crash mid-test, post-run kill). Caller must guarantee `msg.testrun_id !== nothing`.
function _handle_termination_during_run!(c::TestItemController, msg::TestProcessTerminatedMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return
    end

    terminated_proc_id = msg.testprocess_id

    # Resolve the test_env_id from the terminated process's env
    terminated_ps = get(c.test_processes, terminated_proc_id, nothing)
    test_env_id = if terminated_ps !== nothing
        _resolve_test_env_id(tr, terminated_ps.env)
    else
        first(tr.test_environments).id
    end

    # Collect remaining items from the dead process's queue.
    items_to_redistribute = String[]
    if haskey(tr.testitem_ids_by_proc, terminated_proc_id)
        for testitem_id in tr.testitem_ids_by_proc[terminated_proc_id]
            if haskey(tr.remaining_work, (testitem_id, test_env_id))
                push!(items_to_redistribute, testitem_id)
            end
        end
        empty!(tr.testitem_ids_by_proc[terminated_proc_id])
    end
    if haskey(tr.stolen_ids_by_proc, terminated_proc_id)
        empty!(tr.stolen_ids_by_proc[terminated_proc_id])
    end

    # Find the environment of the terminated process
    terminated_env = nothing
    if tr.procs !== nothing
        for (env, pids) in pairs(tr.procs)
            idx = findfirst(isequal(terminated_proc_id), pids)
            if idx !== nothing
                terminated_env = env
                deleteat!(pids, idx)
                break
            end
        end
    end

    # Note: pool cleanup runs immediately after this helper returns, in the
    # outer handle!(::TestProcessTerminatedMsg) — no separate message required.

    if isempty(items_to_redistribute)
        @info "Test process '$(terminated_proc_id)' terminated during test run, no remaining items to redistribute"
        _check_testrun_complete!(c, tr)
        return
    end

    # If explicitly terminated by user, error remaining items instead of redistributing
    if msg.skip_remaining
        @info "Test process '$(terminated_proc_id)' terminated by user, erroring $(length(items_to_redistribute)) remaining item(s)"
        for testitem_id in items_to_redistribute
            item = _item_for_env(tr, test_env_id, testitem_id)
            work_key = (testitem_id, test_env_id)
            if haskey(tr.remaining_work, work_key) && item !== nothing
                delete!(tr.remaining_work, work_key)
                push!(tr.reported_items, testitem_id)
                _notify_testitem_errored(c.callbacks,
                    msg.testrun_id,
                    testitem_id,
                    test_env_id,
                    TestMessage[
                        TestMessage(
                            "Test process terminated by user for test item '$(item.label)'",
                            nothing,
                            nothing,
                            item.uri,
                            item.line,
                            item.column,
                            nothing
                        )
                    ],
                    nothing
                )
            end
        end
        _check_testrun_complete!(c, tr)
        return
    end

    # If shutting down, skip remaining items instead of redistributing
    if state(c.controller_fsm) != ControllerRunning || terminated_env === nothing
        @info "Test process '$(terminated_proc_id)' terminated, skipping $(length(items_to_redistribute)) remaining item(s) (controller shutting down or env unknown)"
        for testitem_id in items_to_redistribute
            work_key = (testitem_id, test_env_id)
            if haskey(tr.remaining_work, work_key)
                delete!(tr.remaining_work, work_key)
                push!(tr.reported_items, testitem_id)
                _notify_testitem_skipped(c.callbacks, msg.testrun_id, testitem_id, test_env_id)
            end
        end
        _check_testrun_complete!(c, tr)
        return
    end

    # Identify whether the crash happened while a test item was actively running.
    # ps.current_testitem_id is set in TestItemStartedMsg and cleared in _cancel_timeout!
    # (called on passed/failed/errored). It is NOT cleared by _kill_julia_process!, and
    # the outer cleanup runs only after this helper returns, so the entry is still here.
    ps = haskey(c.test_processes, terminated_proc_id) ? c.test_processes[terminated_proc_id] : nothing
    crashed_item_id = ps !== nothing ? ps.current_testitem_id : nothing

    # A memory recycle is a clean, deliberate exit taken *between* items, after the last
    # result was reported — so there is no in-flight item to blame, and the remaining items
    # go through the ordinary redistribute-or-respawn path below rather than being errored.
    recycled = ps !== nothing && ps.last_exit_code == MEMORY_RECYCLE_EXIT_CODE
    @debug "Termination classification" testprocess_id=terminated_proc_id exit_code=(ps === nothing ? :no_ps : ps.last_exit_code) term_signal=(ps === nothing ? :no_ps : ps.last_term_signal) recycled
    if recycled
        @info "Test process '$(terminated_proc_id)' stopped itself to release memory, redistributing $(length(items_to_redistribute)) remaining item(s)"
        _cancel_timeout!(ps)
        crashed_item_id = nothing
    end

    crashed_work_key = crashed_item_id !== nothing ? (crashed_item_id, test_env_id) : nothing
    if crashed_item_id !== nothing && haskey(tr.remaining_work, crashed_work_key)
        # A test item was actively running when the process crashed — error it immediately.
        item = _item_for_env(tr, test_env_id, crashed_item_id)
        # The details are only needed to describe the crash; the item must be reported as
        # errored either way, so fall back to its id rather than letting a lookup miss
        # decide whether a test run completes.
        item_label = item === nothing ? crashed_item_id : item.label
        delete!(tr.remaining_work, crashed_work_key)
        filter!(!isequal(crashed_item_id), items_to_redistribute)
        _cancel_timeout!(ps)
        exit_info = ps !== nothing ? _exit_info_string(ps.last_exit_code, ps.last_term_signal) : nothing
        crash_detail = exit_info !== nothing ? " ($exit_info)" : ""
        @info "Test process '$(terminated_proc_id)' crashed$(crash_detail) while running test item '$(item_label)', erroring it immediately"
        error_message = if exit_info !== nothing
            "Test process crashed with $exit_info while running test item '$(item_label)'"
        else
            "Test process crashed while running test item '$(item_label)'"
        end
        push!(tr.reported_items, crashed_item_id)
        _notify_testitem_errored(c.callbacks,
            msg.testrun_id,
            crashed_item_id,
            test_env_id,
            TestMessage[
                TestMessage(
                    error_message,
                    nothing,
                    nothing,
                    item === nothing ? "" : item.uri,
                    item === nothing ? 0 : item.line,
                    item === nothing ? 0 : item.column,
                    nothing
                )
            ],
            nothing
        )
    elseif crashed_item_id === nothing
        # No item was actively running when the process died.
        # Distinguish startup crash from post-run kill (timeout handler, etc.)
        # by checking whether the process ever reached ProcessRunning.
        process_was_running = ps !== nothing && state(ps.fsm) in (ProcessRunning, ProcessIdle)
        if !process_was_running
            # True startup crash — process never ran any item. Error all queued items.
            @info "Test process '$(terminated_proc_id)' crashed during startup, erroring $(length(items_to_redistribute)) queued item(s)"
            for testitem_id in items_to_redistribute
                item = _item_for_env(tr, test_env_id, testitem_id)
                work_key = (testitem_id, test_env_id)
                if haskey(tr.remaining_work, work_key) && item !== nothing
                    delete!(tr.remaining_work, work_key)
                    push!(tr.reported_items, testitem_id)
                    _notify_testitem_errored(c.callbacks,
                        msg.testrun_id,
                        testitem_id,
                        test_env_id,
                        TestMessage[
                            TestMessage(
                                "Test process crashed before running test item '$(item.label)'",
                                nothing,
                                nothing,
                                item.uri,
                                item.line,
                                item.column,
                                nothing
                            )
                        ],
                        nothing
                    )
                end
            end
            _check_testrun_complete!(c, tr)
            return
        elseif ps !== nothing && !ps.has_started_items
            # Process reached ProcessRunning but crashed before any TestItemStartedMsg
            # was received — no item ever began executing. Error all queued items.
            @info "Test process '$(terminated_proc_id)' crashed before starting any test item, erroring $(length(items_to_redistribute)) queued item(s)"
            for testitem_id in items_to_redistribute
                item = _item_for_env(tr, test_env_id, testitem_id)
                work_key = (testitem_id, test_env_id)
                if haskey(tr.remaining_work, work_key) && item !== nothing
                    delete!(tr.remaining_work, work_key)
                    push!(tr.reported_items, testitem_id)
                    _notify_testitem_errored(c.callbacks,
                        msg.testrun_id,
                        testitem_id,
                        test_env_id,
                        TestMessage[
                            TestMessage(
                                "Test process crashed before starting test item '$(item.label)'",
                                nothing,
                                nothing,
                                item.uri,
                                item.line,
                                item.column,
                                nothing
                            )
                        ],
                        nothing
                    )
                end
            end
            _check_testrun_complete!(c, tr)
            return
        elseif !recycled
            # Process was functional and was killed after running items (e.g., timeout).
            # Fall through to redistribute remaining un-started items. A memory recycle
            # takes the same path but has already said so above, in accurate terms.
            @info "Test process '$(terminated_proc_id)' terminated after running items, redistributing $(length(items_to_redistribute)) remaining item(s)"
        end
    end

    # Redistribute remaining un-started items (if any) to another process.
    if isempty(items_to_redistribute)
        _check_testrun_complete!(c, tr)
        return
    end

    # Never call a memory recycle a crash: this is the diagnostic path the feature exists to
    # keep readable, and a deliberate exit reported as a crash sends anyone reading a CI log
    # looking for a fault that isn't there.
    @info "Redistributing $(length(items_to_redistribute)) un-started item(s) from $(recycled ? "recycled" : "crashed") process '$(terminated_proc_id)'"

    # Try to find another live process in the same env
    recipient_pid = nothing
    if tr.procs !== nothing && haskey(tr.procs, terminated_env)
        for pid in tr.procs[terminated_env]
            if pid != terminated_proc_id && haskey(c.test_processes, pid) && state(c.test_processes[pid].fsm) != ProcessDead && c.test_processes[pid].endpoint !== nothing && isopen(c.test_processes[pid].endpoint)
                recipient_pid = pid
                break
            end
        end
    end

    if recipient_pid !== nothing
        # Redistribute to existing process
        rps = c.test_processes[recipient_pid]
        append!(get!(tr.testitem_ids_by_proc, recipient_pid, String[]), items_to_redistribute)

        items_to_run = _items_for(tr, test_env_id, items_to_redistribute)
        @info "Redistributing $(length(items_to_run)) item(s) to existing process '$(recipient_pid)'"
        _send_run_testitems!(c, rps, items_to_run)
    else
        # Create a new replacement process for the un-started items
        env = terminated_env

        env_content_hash = tr.env_by_id[test_env_id].env_content_hash

        # Resolve log_level from the first remaining work unit
        log_level = :Info
        for tid in items_to_redistribute
            wu = get(tr.remaining_work, (tid, test_env_id), nothing)
            if wu !== nothing
                log_level = wu.log_level
                break
            end
        end

        @info "Creating new replacement process for package '$(env.package_name)'"

        precompile_already_done = env in c.precompiled_envs

        testprocess_id = string(UUIDs.uuid4())

        new_ps = TestProcessState(testprocess_id, env;
            is_precompile_process=precompile_already_done,
            precompile_done=precompile_already_done,
            test_env_content_hash=env_content_hash)
        new_ps.testrun_id = msg.testrun_id
        c.test_processes[testprocess_id] = new_ps

        pool_ids = get!(c.process_pool, env) do; String[]; end
        push!(pool_ids, testprocess_id)

        if tr.procs !== nothing
            push!(get!(tr.procs, env) do; String[]; end, testprocess_id)
        end

        tr.testitem_ids_by_proc[testprocess_id] = items_to_redistribute
        tr.stolen_ids_by_proc[testprocess_id] = String[]

        testrun_token = CancellationTokens.get_token(tr.cancellation_source)

        server_test_setups = [
            TestItemServerProtocol.TestsetupDetails(
                packageUri = i.package_uri,
                name = i.name,
                kind = i.kind,
                uri = i.uri,
                line = i.line,
                column = i.column,
                code = i.code
            ) for i in tr.test_setups
        ]

        _setup_testrun_on_process!(new_ps, msg.testrun_id, server_test_setups, tr.coverage_root_uris, log_level, testrun_token)

        transition!(new_ps.fsm, ProcessStarting; reason="replacement process")
        _launch_julia_process!(c, new_ps)

        if c.callbacks.on_process_created !== nothing
            c.callbacks.on_process_created(testprocess_id, test_env_id)
        end
    end

    return
end

# The outbound half of a process's JSON-RPC connection, when the JSONRPC in use can report
# it. That queue is unbounded, so a peer that has stopped reading never makes a send fail —
# the messages simply accumulate, undelivered. Guarded by `isdefined` because the compat
# bound still allows a JSONRPC without the accessor.
function _outbound_backlog(ps::TestProcessState)
    ps.endpoint === nothing && return nothing
    isdefined(JSONRPC, :outbound_backlog) || return nothing
    return try
        JSONRPC.outbound_backlog(ps.endpoint)
    catch
        nothing
    end
end

"""
What the controller knows about a process at the moment one of its items timed out, as
`@warn` key/value pairs.

A test process talks to the controller over two independent channels: the JSON-RPC socket
that carries every result, and the stdout/stderr pipes that carry captured output. A timeout
is only evidence that the *result* never arrived, and these two clocks are what separate the
cases. Output still arriving while the socket has gone quiet means the connection died, not
the test — which is exactly what happened in
<https://github.com/JuliaControl/ModelPredictiveControl.jl/actions/runs/32420160289>, where a
test item that had passed 17/17 in 9.8 seconds was reported as a one-hour hang and the only
way to tell was to reconstruct it from the run's artifacts afterwards.
"""
function _timeout_evidence(ps::TestProcessState, diagnostics::Union{Nothing,AbstractString})
    now = time()
    elapsed(t) = t === nothing ? nothing : round(now - t, digits=1)
    backlog = _outbound_backlog(ps)
    return (
        seconds_since_last_message = elapsed(ps.last_message_at),
        seconds_since_last_output = elapsed(ps.last_output_at),
        watchdog_dump = diagnostics !== nothing,
        outbound_queued = backlog === nothing ? nothing : backlog.queued,
        outbound_blocked_seconds = backlog === nothing ? nothing : round(backlog.blocked_seconds, digits=1),
    )
end

function handle!(c::TestItemController, msg::TestItemTimeoutMsg)
    if !haskey(c.test_runs, msg.testrun_id) || !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    ps = c.test_processes[msg.testprocess_id]

    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    # Guard against stale timeout
    if ps.current_testitem_id != msg.testitem_id
        return false
    end

    # Resolve test_env_id
    test_env_id = _resolve_test_env_id(tr, ps.env)

    item = _item_for_env(tr, test_env_id, msg.testitem_id)
    work_key = (msg.testitem_id, test_env_id)
    wu = get(tr.remaining_work, work_key, nothing)
    item_label = item !== nothing ? item.label : msg.testitem_id
    timeout_val = wu !== nothing && wu.timeout !== nothing ? wu.timeout : "?"

    # Read before the warning, so it can report whether the process's own watchdog believed
    # the item was still running. The dump is absent when the item wedged without ever
    # reaching a GC safepoint, or when the process has no spare thread to run the watchdog
    # on — so its absence is evidence, not proof.
    diagnostics = _read_diagnostics(msg.testprocess_id)

    @warn "Test item '$(item_label)' timed out after $(timeout_val) seconds" testprocess_id=msg.testprocess_id _timeout_evidence(ps, diagnostics)...

    # Attach whatever the watchdog managed to dump, so the backtrace shows up as that item's
    # output.
    if diagnostics !== nothing
        c.callbacks.on_append_output(msg.testrun_id, msg.testitem_id, test_env_id, replace(diagnostics, "\n"=>"\r\n"))
    end

    _cancel_timeout!(ps)

    # Report item as errored
    if haskey(tr.remaining_work, work_key)
        delete!(tr.remaining_work, work_key)
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)

        push!(tr.reported_items, msg.testitem_id)
        _notify_testitem_errored(c.callbacks,
            msg.testrun_id,
            msg.testitem_id,
            test_env_id,
            TestMessage[
                TestMessage(
                    "Test item '$(item_label)' timed out after $(timeout_val) seconds",
                    nothing,
                    nothing,
                    item !== nothing ? item.uri : nothing,
                    item !== nothing ? item.line : nothing,
                    item !== nothing ? item.column : nothing,
                    nothing
                )
            ],
            nothing
        )
    end

    # Terminate the process via its cancellation source. start()'s IO task will
    # post a single TestProcessTerminatedMsg once the process actually exits,
    # which the merged handler uses to redistribute any remaining items.
    _kill_julia_process!(ps)
    return false
end

# ═══════════════════════════════════════════════════════════════════════════════
# Process-lifecycle handlers (from IO tasks)
# ═══════════════════════════════════════════════════════════════════════════════

function handle!(c::TestItemController, msg::TestProcessLaunchedMsg)
    @debug "Handling TestProcessLaunchedMsg" testprocess_id=msg.testprocess_id process_known=haskey(c.test_processes, msg.testprocess_id)
    if !haskey(c.test_processes, msg.testprocess_id)
        # Process was removed (e.g. shutdown), kill the stale Julia process
        _kill_julia_process_resources!(msg.jl_process, msg.endpoint)
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) != ProcessStarting
        # Process was cancelled/dead while starting, kill the stale process
        @debug "Ignoring TestProcessLaunchedMsg in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        _kill_julia_process_resources!(msg.jl_process, msg.endpoint)
        return false
    end

    ps.jl_process = msg.jl_process
    ps.endpoint = msg.endpoint

    if ps.testrun_id === nothing
        # Process launched but testrun already ended (e.g. cancelled while starting)
        transition!(ps.fsm, ProcessIdle; reason="launched_without_testrun")
        return false
    end

    if ps.is_precompile_process || ps.precompile_done
        @debug "Activating environment after launch" testprocess_id=msg.testprocess_id precompile_process=ps.is_precompile_process precompile_done=ps.precompile_done
        transition!(ps.fsm, ProcessActivatingEnv; reason="testprocess_launched")
        _activate_env!(c, ps)
    else
        transition!(ps.fsm, ProcessWaitingForPrecompile; reason="waiting_for_peer_precompile")
    end

    return false
end

function handle!(c::TestItemController, msg::TestProcessActivatedMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) != ProcessActivatingEnv
        @debug "Ignoring TestProcessActivatedMsg in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        return false
    end

    if ps.testrun_id !== nothing && haskey(c.test_runs, ps.testrun_id) && state(c.test_runs[ps.testrun_id].fsm) in (TestRunCancelled, TestRunCompleted)
        @debug "Test run already ended, returning process to idle" testprocess_id=msg.testprocess_id
        transition!(ps.fsm, ProcessDead; reason="testrun_cancelled_during_activation")
        put!(c.reactor_channel, ReturnToPoolMsg(msg.testprocess_id, ps.env))
        return false
    end

    transition!(ps.fsm, ProcessConfiguringTestRun; reason="testprocess_activated")

    if ps.env.mode == "Debug" && ps.testrun_id !== nothing
        @debug "Requesting debugger attachment" testprocess_id=msg.testprocess_id debug_pipe_name=ps.debug_pipe_name
        put!(c.reactor_channel, AttachDebuggerMsg(ps.testrun_id, ps.debug_pipe_name))
    end

    @debug "Configuring test run on process" testprocess_id=msg.testprocess_id mode=ps.env.mode
    _configure_testrun!(c, ps)

    return false
end

function handle!(c::TestItemController, msg::TestProcessTestSetupsLoadedMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) != ProcessConfiguringTestRun
        @debug "Ignoring TestProcessTestSetupsLoadedMsg in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        return false
    end

    if ps.testrun_id !== nothing && haskey(c.test_runs, ps.testrun_id) && state(c.test_runs[ps.testrun_id].fsm) in (TestRunCancelled, TestRunCompleted)
        @debug "Test run already ended, returning process to idle" testprocess_id=msg.testprocess_id
        transition!(ps.fsm, ProcessDead; reason="testrun_cancelled_during_configuration")
        put!(c.reactor_channel, ReturnToPoolMsg(msg.testprocess_id, ps.env))
        return false
    end

    transition!(ps.fsm, ProcessReadyToRun; reason="testprocess_testsetups_loaded")
    @info "Process is ready to run test items" testprocess_id=msg.testprocess_id

    if ps.testrun_id !== nothing
        put!(c.reactor_channel, ReadyToRunTestItemsMsg(ps.testrun_id, msg.testprocess_id))
    end

    return false
end

function handle!(c::TestItemController, msg::TestProcessReviseResultMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) != ProcessRevising
        @debug "Ignoring TestProcessReviseResultMsg in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        return false
    end

    if ps.testrun_id !== nothing && haskey(c.test_runs, ps.testrun_id) && state(c.test_runs[ps.testrun_id].fsm) in (TestRunCancelled, TestRunCompleted)
        @debug "Test run already ended during revise, returning process to pool" testprocess_id=msg.testprocess_id
        transition!(ps.fsm, ProcessIdle; reason="testrun_cancelled_during_revise")
        put!(c.reactor_channel, ReturnToPoolMsg(msg.testprocess_id, ps.env))
        return false
    end

    if msg.needs_restart
        @debug "Revise requested restart" testprocess_id=msg.testprocess_id
        tr = ps.testrun_id !== nothing && haskey(c.test_runs, ps.testrun_id) ? c.test_runs[ps.testrun_id] : nothing
        replacement_ps, _ = _replace_process_state!(
            c,
            ps;
            tr=tr,
            test_env_content_hash=ps.test_env_content_hash,
            is_precompile_process=ps.is_precompile_process,
            precompile_done=ps.precompile_done,
            preserve_testrun=true,
        )
        transition!(replacement_ps.fsm, ProcessStarting; reason="restart_after_revise")
        _launch_julia_process!(c, replacement_ps)
        if tr !== nothing && c.callbacks.on_process_created !== nothing
            c.callbacks.on_process_created(replacement_ps.id, _resolve_test_env_id(tr, replacement_ps.env))
        end
    else
        @debug "Revise completed without restart, skipping activation" testprocess_id=msg.testprocess_id
        transition!(ps.fsm, ProcessConfiguringTestRun; reason="revise_success")

        if ps.env.mode == "Debug" && ps.testrun_id !== nothing
            @debug "Requesting debugger attachment" testprocess_id=msg.testprocess_id debug_pipe_name=ps.debug_pipe_name
            put!(c.reactor_channel, AttachDebuggerMsg(ps.testrun_id, ps.debug_pipe_name))
        end

        @debug "Configuring test run on process" testprocess_id=msg.testprocess_id mode=ps.env.mode
        _configure_testrun!(c, ps)
    end

    return false
end

function handle!(c::TestItemController, msg::ActivationFailedMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        error("Received ActivationFailedMsg for unknown process ID '$(msg.testprocess_id)'")
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) != ProcessActivatingEnv
        error("Received ActivationFailedMsg for process '$(msg.testprocess_id)' in unexpected state '$(state(ps.fsm))'")
    end

    @warn "Environment activation failed for process" testprocess_id=msg.testprocess_id is_precompile=ps.is_precompile_process error=msg.error_message

    if ps.testrun_id === nothing || !haskey(c.test_runs, ps.testrun_id)
        error("Received ActivationFailedMsg for process '$(msg.testprocess_id)' with unknown or missing testrun ID '$(ps.testrun_id)'")
    end

    tr = c.test_runs[ps.testrun_id]
    testrun_id = ps.testrun_id

    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        _kill_julia_process!(ps)
        transition!(ps.fsm, ProcessDead; reason="activation_failed_testrun_ended")
        return false
    end

    if ps.is_precompile_process
        # Precompile process failure is deterministic — all processes for this env will fail.
        # Error ALL remaining items for this environment and kill all peer processes.
        env = ps.env
        test_env_id = _resolve_test_env_id(tr, env)

        # Collect all items for this environment
        items_to_error = String[]
        if tr.procs !== nothing && haskey(tr.procs, env)
            for pid in tr.procs[env]
                if haskey(tr.testitem_ids_by_proc, pid)
                    for testitem_id in tr.testitem_ids_by_proc[pid]
                        if haskey(tr.remaining_work, (testitem_id, test_env_id))
                            push!(items_to_error, testitem_id)
                        end
                    end
                    empty!(tr.testitem_ids_by_proc[pid])
                end
            end
        end

        # Error all collected items
        for testitem_id in items_to_error
            work_key = (testitem_id, test_env_id)
            item = _item_for_env(tr, test_env_id, testitem_id)
            if haskey(tr.remaining_work, work_key) && item !== nothing
                delete!(tr.remaining_work, work_key)
                push!(tr.reported_items, testitem_id)
                _notify_testitem_errored(c.callbacks,
                    testrun_id,
                    testitem_id,
                    test_env_id,
                    TestMessage[
                        TestMessage(
                            "Environment activation failed for package '$(env.package_name)': $(msg.error_message)",
                            nothing,
                            nothing,
                            item.uri,
                            item.line,
                            item.column,
                            nothing
                        )
                    ],
                    nothing
                )
            end
        end

        # Kill all peer processes for this environment (they're waiting for precompile that will never come)
        if tr.procs !== nothing && haskey(tr.procs, env)
            for pid in tr.procs[env]
                if haskey(c.test_processes, pid)
                    peer = c.test_processes[pid]
                    _kill_julia_process!(peer)
                    if state(peer.fsm) != ProcessDead
                        transition!(peer.fsm, ProcessDead; reason="activation_failed_precompile_process")
                    end
                end
            end
        end
    else
        # Non-precompile process — error only items assigned to this process
        test_env_id = _resolve_test_env_id(tr, ps.env)
        if haskey(tr.testitem_ids_by_proc, ps.id)
            for testitem_id in tr.testitem_ids_by_proc[ps.id]
                work_key = (testitem_id, test_env_id)
                item = _item_for_env(tr, test_env_id, testitem_id)
                if haskey(tr.remaining_work, work_key) && item !== nothing
                    delete!(tr.remaining_work, work_key)
                    push!(tr.reported_items, testitem_id)
                    _notify_testitem_errored(c.callbacks,
                        testrun_id,
                        testitem_id,
                        test_env_id,
                        TestMessage[
                            TestMessage(
                                "Environment activation failed for package '$(ps.env.package_name)': $(msg.error_message)",
                                nothing,
                                nothing,
                                item.uri,
                                item.line,
                                item.column,
                                nothing
                            )
                        ],
                        nothing
                    )
                end
            end
            empty!(tr.testitem_ids_by_proc[ps.id])
        end

        _kill_julia_process!(ps)
        transition!(ps.fsm, ProcessDead; reason="activation_failed")
    end

    _check_testrun_complete!(c, tr)

    return false
end

function handle!(c::TestItemController, msg::TestProcessIOErrorMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) == ProcessDead
        @debug "Ignoring IO error for process in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        return false
    end
    # An *idle* process used to be ignored here too. That left a pooled process whose pipe
    # had broken registered as alive: it would be handed out again later, and — worse — at
    # shutdown the reactor waited forever for a `TestProcessTerminatedMsg` that its IO task,
    # having taken the error path, was never going to post. Fall through: with no test run
    # attached it cannot take the restart branch, so it is terminated and forgotten below.

    @debug "Test process IO error" testprocess_id=msg.testprocess_id error_type=msg.error_type fsm_state=state(ps.fsm) has_testrun=(ps.testrun_id !== nothing) testrun_id=something(ps.testrun_id, "none") exit_code=msg.exit_code term_signal=msg.term_signal

    # Store exit info on the process state so downstream handlers can access it.
    ps.last_exit_code = msg.exit_code
    ps.last_term_signal = msg.term_signal

    _kill_julia_process!(ps)

    if msg.error_type == :restart && ps.testrun_id !== nothing
        # Restart by replacing process state, then launching a fresh process.
        tr = haskey(c.test_runs, ps.testrun_id) ? c.test_runs[ps.testrun_id] : nothing
        replacement_ps, _ = _replace_process_state!(
            c,
            ps;
            tr=tr,
            test_env_content_hash=ps.test_env_content_hash,
            is_precompile_process=ps.is_precompile_process,
            precompile_done=ps.precompile_done,
            preserve_testrun=true,
        )
        transition!(replacement_ps.fsm, ProcessStarting; reason="restart_after_io_error")
        _launch_julia_process!(c, replacement_ps)
        if tr !== nothing && c.callbacks.on_process_created !== nothing
            c.callbacks.on_process_created(replacement_ps.id, _resolve_test_env_id(tr, replacement_ps.env))
        end
    else
        # Fatal error — terminate. start()'s IO task may or may not have already
        # posted a TestProcessTerminatedMsg depending on which task detected the
        # failure; post one explicitly here so the controller always sees a
        # terminated event for this process even if start() never reaches its
        # own put! (e.g. activation failed before the IO loop started).
        put!(c.reactor_channel, TestProcessTerminatedMsg(ps.id, ps.testrun_id, false))
    end

    return false
end

# ═══════════════════════════════════════════════════════════════════════════════
# Process management helpers
# ═══════════════════════════════════════════════════════════════════════════════

# Build the environment a subprocess for `penv` runs in, applying the test environment's
# overlay (a `nothing` value deletes the variable) on top of ours.
function _subprocess_env(penv::ProcessEnv)
    jlEnv = copy(ENV)

    # During precompilation, Julia restricts JULIA_LOAD_PATH to dependency paths only
    # (no "@" entry), which prevents child processes from using their own active project.
    if ccall(:jl_generating_output, Cint, ()) == 1
        delete!(jlEnv, "JULIA_LOAD_PATH")
    end

    for (ek, ev) in pairs(penv.env)
        if ev !== nothing
            jlEnv[ek] = ev
        elseif haskey(jlEnv, ek)
            delete!(jlEnv, ek)
        end
    end

    return jlEnv
end

# The Julia version a test process for `penv` will run. Two callers need it: the pre-1.10
# precompile hack, and the launch, which may only pass `--threads=N,M` to Julia >= 1.9.
#
# Probing costs a process launch, so the answer is cached per (cmd, args) and the common
# case — the exact binary this controller runs, with no extra args — short-circuits. (A bare
# "julia" must still be probed: PATH or a juliaup channel can resolve it to a different
# version than the running process.) Returns `nothing` when the probe fails, which every
# caller treats as "assume nothing".
function _resolve_julia_version(c::TestItemController, penv::ProcessEnv)
    if isempty(penv.juliaArgs) && penv.juliaCmd == joinpath(Sys.BINDIR, Base.julia_exename())
        return VERSION
    end

    key = (penv.juliaCmd, penv.juliaArgs)
    haskey(c.julia_version_cache, key) && return c.julia_version_cache[key]

    version = try
        version_as_string = read(Cmd(`$(penv.juliaCmd) $(penv.juliaArgs) --version`, detach=false, env=_subprocess_env(penv)), String)
        VersionNumber(version_as_string[length("julia version")+2:end])
    catch err
        @warn "Could not determine the Julia version of '$(penv.juliaCmd)'" exception=(err, catch_backtrace())
        nothing
    end

    version !== nothing && (c.julia_version_cache[key] = version)
    return version
end

# Map common POSIX signal numbers to human-readable names.
const _SIGNAL_NAMES = Dict{Int,String}(
    1  => "SIGHUP",
    2  => "SIGINT",
    3  => "SIGQUIT",
    4  => "SIGILL",
    6  => "SIGABRT",
    7  => "SIGBUS",
    8  => "SIGFPE",
    9  => "SIGKILL",
    11 => "SIGSEGV",
    13 => "SIGPIPE",
    14 => "SIGALRM",
    15 => "SIGTERM",
)

# `Base.Process.termsignal` is `0`, not `nothing`, for a process that exited with a code
# rather than being killed by a signal — so `0` means "no signal" here.
function _signal_name(sig::Union{Nothing,Int})
    (sig === nothing || sig <= 0) && return nothing
    return get(_SIGNAL_NAMES, sig, "signal $sig")
end

# Windows reports fatal errors as NTSTATUS exit codes (e.g. `0xC0000005` for an access
# violation), which Julia surfaces as a negative `Int32`; show the hex form as well since that
# is what people recognise.
function _exit_code_string(exit_code::Int)
    if exit_code < 0 && exit_code >= typemin(Int32)
        return string("exit code ", exit_code, " (0x", uppercase(string(reinterpret(UInt32, Int32(exit_code)), base=16, pad=8)), ")")
    else
        return "exit code $exit_code"
    end
end

function _exit_info_string(exit_code::Union{Nothing,Int}, term_signal::Union{Nothing,Int})
    sig = _signal_name(term_signal)
    if sig !== nothing
        return "$sig (signal $term_signal)"
    elseif exit_code !== nothing
        return _exit_code_string(exit_code)
    else
        return nothing
    end
end

function _kill_julia_process_resources!(jl_process::Union{Nothing,Base.Process}, endpoint::Union{Nothing,JSONRPC.JSONRPCEndpoint})
    # Kill the subprocess BEFORE closing the endpoint. When the process dies,
    # the OS closes its end of the socket, giving the read task an immediate
    # EOF/IOError. This avoids a potential deadlock where close(endpoint)
    # waits for the read task, which waits on the still-alive process.
    if jl_process !== nothing
        try kill(jl_process) catch end
    end
    if endpoint !== nothing
        # This runs inside a cancellation callback, i.e. synchronously on whichever task
        # called `cancel` — normally the reactor. `close(::JSONRPCEndpoint)` blocks until the
        # endpoint's read and write tasks have finished, and if either of those does not
        # come back the reactor is wedged and can never process the termination message it
        # is waiting for. Nothing needs this close to be synchronous: the process IO task in
        # `start` closes the endpoint itself in a `finally`, and its `get_next_message` is
        # unblocked by the process token, not by this close. So do it off the caller.
        @async try close(endpoint) catch end
    end
end

function _register_process_termination_handler!(ps::TestProcessState)
    if ps.termination_reg !== nothing
        try close(ps.termination_reg) catch end
        ps.termination_reg = nothing
    end

    ps.termination_reg = CancellationTokens.register(CancellationTokens.get_token(ps.cs)) do
        if ps.timeout_cs !== nothing
            try CancellationTokens.cancel(ps.timeout_cs) catch end
            ps.timeout_cs = nothing
        end
        if ps.timeout_reg !== nothing
            try close(ps.timeout_reg) catch end
            ps.timeout_reg = nothing
        end
        _kill_julia_process_resources!(ps.jl_process, ps.endpoint)
        ps.jl_process = nothing
        ps.endpoint = nothing
    end
end

function _kill_julia_process!(ps::TestProcessState)
    CancellationTokens.cancel(ps.cs)
end

function _clear_testrun_on_process!(ps::TestProcessState)
    if ps.testrun_watcher_registration !== nothing
        try close(ps.testrun_watcher_registration) catch end
        ps.testrun_watcher_registration = nothing
    end
    ps.testrun_id = nothing
    ps.testrun_token = nothing
    ps.test_setups = nothing
    ps.coverage_root_uris = nothing
    ps.has_started_items = false
end

# Drop cached setup state that the incoming run invalidates.
#
# `ps.loaded_setups` records what a `@testmodule`/`@testsnippet` cost and printed on this
# process. The test process re-evaluates a setup whose code changed, so a cost measured
# against the old body no longer describes it — and the scheduler would go on pricing warm
# affinity for a setup this process can no longer reproduce.
#
# Called for every run on a pooled process, which is what makes it cover the Revise case
# too: revised source reaches the process as changed setup code here, not through a separate
# path. Deliberately conservative — a setup cached under an earlier run that this one does
# not mention is dropped rather than assumed intact. Losing a cost hint only costs us a
# scheduling opportunity; keeping a wrong one produces a worse schedule and hides why.
function _invalidate_stale_setups!(ps::TestProcessState, new_setups)
    isempty(ps.loaded_setups) && return nothing

    previous = ps.test_setups === nothing ? Dict{Tuple{String,String},String}() :
        Dict((i.packageUri, i.name) => i.code for i in ps.test_setups)
    incoming = new_setups === nothing ? Dict{Tuple{String,String},String}() :
        Dict((i.packageUri, i.name) => i.code for i in new_setups)

    filter!(ps.loaded_setups) do (key, _)
        haskey(incoming, key) && get(previous, key, nothing) == incoming[key]
    end
    return nothing
end

# Every test item in a run must be individually addressable, or the run silently loses one:
# the state dicts are keyed by `(id, package_uri)`, so a genuine duplicate would overwrite its
# twin and that item would never run, never report, and never appear in the results.
#
# Two items sharing an *id* is legitimate and must not error — that is the same package
# checked out twice, which the package_uri separates. What cannot happen is a collision on
# the full key, since discovery already suffixes duplicate labels within a file with `#N`.
# So this should never fire; it exists so that a future mistake in the id scheme surfaces as
# an error here rather than as a test that quietly stopped running.
function _assert_addressable_items(test_items::Vector{TestItemDetail})
    seen = Dict{Tuple{String,String},TestItemDetail}()
    for item in test_items
        key = (item.id, item.package_uri)
        previous = get(seen, key, nothing)
        if previous !== nothing
            throw(ArgumentError(
                "Two test items in this run share the id '$(item.id)' within the same package " *
                "('$(item.package_uri)'), so one of them could not be run or reported. " *
                "First at $(previous.uri):$(previous.line), second at $(item.uri):$(item.line)."))
        end
        seen[key] = item
    end
    return nothing
end

# Test item details, looked up for the package a given process is running. Ids are scoped to
# their package, so the id alone does not identify an item when the same package is checked
# out twice in one workspace — see the `test_items` field comment in `state.jl`.
# One test item's details for the environment a process belongs to, or `nothing`.
#
# Returns `nothing` rather than throwing on a miss, and tolerates an unknown environment.
# Both matter here: these lookups run on the process-termination path, and an exception
# thrown out of a reactor handler does not surface as a failed test item — it kills the
# reactor loop, so the run never completes and the caller waits until its timeout. A missing
# detail should degrade to a generic message, not a hang.
function _item_for_env(tr::TestRunState, test_env_id::Union{Nothing,AbstractString}, testitem_id::AbstractString)
    test_env_id === nothing && return nothing
    return get(tr.test_items, (testitem_id, test_env_id), nothing)
end

_items_for(tr::TestRunState, test_env_id::AbstractString, ids) =
    TestItemDetail[tr.test_items[(id, test_env_id)] for id in ids if haskey(tr.test_items, (id, test_env_id))]

function _setup_testrun_on_process!(ps::TestProcessState, testrun_id::String, test_setups, coverage_root_uris, log_level::Symbol, testrun_token)
    _invalidate_stale_setups!(ps, test_setups)
    ps.testrun_id = testrun_id
    ps.testrun_token = testrun_token
    ps.test_setups = test_setups
    ps.coverage_root_uris = coverage_root_uris
    ps.proc_log_level = log_level
end

function _replace_process_state!(
        c::TestItemController,
        ps::TestProcessState;
        tr::Union{Nothing,TestRunState}=nothing,
        test_env_content_hash=ps.test_env_content_hash,
        is_precompile_process::Bool=ps.is_precompile_process,
        precompile_done::Bool=ps.precompile_done,
        preserve_testrun::Bool=true,
    )
    old_id = ps.id
    env = ps.env

    new_id = string(UUIDs.uuid4())
    new_ps = TestProcessState(new_id, env;
        is_precompile_process=is_precompile_process,
        precompile_done=precompile_done,
        test_env_content_hash=test_env_content_hash)

    if preserve_testrun && ps.testrun_id !== nothing
        _setup_testrun_on_process!(new_ps, ps.testrun_id, ps.test_setups, ps.coverage_root_uris, ps.proc_log_level, ps.testrun_token)
    end

    c.test_processes[new_id] = new_ps

    pool_ids = get!(c.process_pool, env) do
        String[]
    end
    idx = findfirst(isequal(old_id), pool_ids)
    if idx === nothing
        push!(pool_ids, new_id)
    else
        pool_ids[idx] = new_id
    end

    if tr !== nothing
        if tr.procs !== nothing && haskey(tr.procs, env)
            tr_idx = findfirst(isequal(old_id), tr.procs[env])
            if tr_idx !== nothing
                tr.procs[env][tr_idx] = new_id
            end
        end

        if haskey(tr.testitem_ids_by_proc, old_id)
            tr.testitem_ids_by_proc[new_id] = tr.testitem_ids_by_proc[old_id]
            delete!(tr.testitem_ids_by_proc, old_id)
        end
        if haskey(tr.stolen_ids_by_proc, old_id)
            tr.stolen_ids_by_proc[new_id] = tr.stolen_ids_by_proc[old_id]
            delete!(tr.stolen_ids_by_proc, old_id)
        end
        if old_id in tr.items_dispatched_to_procs
            delete!(tr.items_dispatched_to_procs, old_id)
            push!(tr.items_dispatched_to_procs, new_id)
        end
        if old_id in tr.processes_ready_before_acquired
            delete!(tr.processes_ready_before_acquired, old_id)
            push!(tr.processes_ready_before_acquired, new_id)
        end
    end

    append!(new_ps.process_tasks, ps.process_tasks)

    _kill_julia_process!(ps)

    if ps.termination_reg !== nothing
        try close(ps.termination_reg) catch end
        ps.termination_reg = nothing
    end
    if ps.testrun_watcher_registration !== nothing
        try close(ps.testrun_watcher_registration) catch end
        ps.testrun_watcher_registration = nothing
    end

    delete!(c.test_processes, old_id)

    return new_ps, old_id
end

# Hand `execute_testrun` its result. `completion_channel` is `Channel{Any}(1)`; a `put!` on a
# full channel does not throw, it *blocks* — and this runs on the reactor, so the old
# `try put! catch end` was no protection at all when a run was signalled twice (a shutdown
# racing a completing run, say). A value already sitting in the channel means the run has
# been signalled; the waiter only ever takes once.
function _signal_testrun_completion!(tr::TestRunState, value)
    ch = tr.completion_channel
    try
        if !isready(ch) && isopen(ch)
            put!(ch, value)
        end
    catch err
        @debug "Could not signal test run completion" testrun_id=tr.id exception=err
    end
    return nothing
end

function _shutdown_test_process!(c::TestItemController, ps::TestProcessState)
    @debug "Shutting down test process" testprocess_id=ps.id
    _kill_julia_process!(ps)
end

function _launch_julia_process!(c::TestItemController, ps::TestProcessState)
    _register_process_termination_handler!(ps)

    # Generate a fresh debug pipe name for every launch so the new child
    # process never collides with a stale pipe from a previous incarnation.
    ps.debug_pipe_name = JSONRPC.generate_pipe_name()

    launch_token = CancellationTokens.get_token(ps.cs)

    @debug "Launching Julia process for test process" testprocess_id=ps.id package=ps.env.package_name mode=ps.env.mode is_precompile=ps.is_precompile_process precompile_done=ps.precompile_done testrun_id=something(ps.testrun_id, "none")
    put!(c.reactor_channel, TestProcessStatusChangedMsg(ps.id, "Launching"))

    # Resolved here rather than in `start` so the (possibly probing) lookup stays on the
    # reactor, where it is serialized and cached, instead of racing across IO tasks.
    julia_version = _resolve_julia_version(c, ps.env)

    t = @async try
        start(ps.id, c.reactor_channel, ps, ps.env, ps.debug_pipe_name,
              c.error_handler_file, c.crash_reporting_pipename,
              julia_version, launch_token)
    catch err
        @error "Error in test process IO" testprocess_id=ps.id exception=(err, catch_backtrace())
    end
    push!(ps.process_tasks, t)
end

function _activate_env!(c::TestItemController, ps::TestProcessState)
    if ps.endpoint === nothing || !isopen(ps.endpoint)
        @warn "Cannot activate environment: process has no endpoint" testprocess_id=ps.id
        try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal)) catch end
        return
    end
    put!(c.reactor_channel, TestProcessStatusChangedMsg(ps.id, "Activating"))
    @async try
        if ps.endpoint === nothing || !isopen(ps.endpoint)
            @debug "Activation cancelled: endpoint gone before send" testprocess_id=ps.id
            return
        end
        # Say so, repeatedly, while this is outstanding. The request covers the test
        # process's own precompilation, so a slow one is legitimate and is not interrupted
        # here — but without this the controller goes silent between the "Activating" status
        # and whatever eventually gives up, and a run that stalls in activation leaves a log
        # that names neither the stage nor the process.
        interval = c.activation_progress_seconds
        started = time()
        progress_timer = Timer(interval, interval=interval) do _
            @warn "Environment activation still pending" testprocess_id=ps.id package=ps.env.package_name elapsed_seconds=round(time() - started, digits=1)
        end
        result = try
            JSONRPC.send(
                ps.endpoint,
                TestItemServerProtocol.testserver_activate_env_request_type,
                TestItemServerProtocol.ActivateEnvParams(
                    projectUri = something(ps.env.project_uri, missing),
                    packageUri = ps.env.package_uri,
                    packageName = ps.env.package_name
                )
            )
        finally
            close(progress_timer)
        end

        if result.status == "failed"
            @warn "Environment activation failed" testprocess_id=ps.id error=coalesce(result.error, "unknown error")
            put!(c.reactor_channel, ActivationFailedMsg(ps.id, coalesce(result.error, "Environment activation failed")))
            return
        end

        if ps.is_precompile_process && ps.testrun_id !== nothing
            put!(c.reactor_channel, PrecompileDoneMsg(ps.testrun_id, ps.env, ps.id))
        end
        put!(c.reactor_channel, TestProcessActivatedMsg(ps.id))
    catch err
        if err isa JSONRPC.TransportError
            @debug "Activation failed (transport error, likely cancelled)" testprocess_id=ps.id exception=(err, catch_backtrace())
        else
            @warn "Error activating environment" testprocess_id=ps.id exception=(err, catch_backtrace())
            try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal)) catch end
        end
    end
end

function _configure_testrun!(c::TestItemController, ps::TestProcessState)
    if ps.endpoint === nothing || !isopen(ps.endpoint)
        @warn "Cannot configure test run: process has no endpoint" testprocess_id=ps.id
        try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal)) catch end
        return
    end
    # Read off the reactor, before the async send: `ps.testrun_id` may be cleared by the
    # time the task runs.
    tr = ps.testrun_id !== nothing ? get(c.test_runs, ps.testrun_id, nothing) : nothing
    gc_between_testitems = tr !== nothing ? tr.gc_between_testitems : false
    memory_threshold = tr !== nothing ? tr.memory_threshold : nothing

    @async try
        if ps.endpoint === nothing || !isopen(ps.endpoint)
            @debug "Configuration cancelled: endpoint gone before send" testprocess_id=ps.id
            return
        end
        JSONRPC.send(
            ps.endpoint,
            TestItemServerProtocol.configure_testrun_request_type,
            TestItemServerProtocol.ConfigureTestRunRequestParams(
                mode = ps.env.mode,
                logLevel = string(ps.proc_log_level),
                coverageRootUris = something(ps.coverage_root_uris, missing),
                testSetups = ps.test_setups,
                gcBetweenTestitems = gc_between_testitems,
                memoryThreshold = something(memory_threshold, missing)
            )
        )
        put!(c.reactor_channel, TestProcessTestSetupsLoadedMsg(ps.id))
    catch err
        if err isa JSONRPC.TransportError
            @debug "Configuration failed (transport error, likely cancelled)" testprocess_id=ps.id exception=(err, catch_backtrace())
        else
            @warn "Error configuring test run" testprocess_id=ps.id exception=(err, catch_backtrace())
            try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal)) catch end
        end
    end
end

# The wire format carries the `skip` kwarg as source text, because the test process is what
# evaluates it. A literal is sent as `"true"`/`"false"` rather than being resolved here, so
# the test process has a reason string to report either way; `false` is left off entirely.
_skip_source(option_skip::Bool) = option_skip ? "true" : missing
_skip_source(option_skip::AbstractString) = String(option_skip)

function _send_run_testitems!(c::TestItemController, ps::TestProcessState, items)
    if ps.endpoint === nothing || !isopen(ps.endpoint)
        @warn "Cannot send test items: process has no endpoint" testprocess_id=ps.id
        try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal)) catch end
        return
    end
    put!(c.reactor_channel, TestProcessStatusChangedMsg(ps.id, "Running"))

    # Resolved on the reactor, where the run state is safe to read. The test process arms
    # its hang watchdog from this; the controller's own timeout stays the backstop.
    tr = ps.testrun_id !== nothing ? get(c.test_runs, ps.testrun_id, nothing) : nothing
    test_env_id = tr !== nothing ? _resolve_test_env_id(tr, ps.env) : nothing
    timeouts_ms = Dict{String,Union{Missing,Float64}}()
    if tr !== nothing
        for i in items
            wu = get(tr.remaining_work, (i.id, test_env_id), nothing)
            timeouts_ms[i.id] = wu !== nothing && wu.timeout !== nothing ? wu.timeout * 1000 : missing
        end
    end

    @async try
        if ps.endpoint === nothing || !isopen(ps.endpoint)
            @debug "Run cancelled: endpoint gone before send" testprocess_id=ps.id
            return
        end
        JSONRPC.send(
            ps.endpoint,
            TestItemServerProtocol.testserver_run_testitems_batch_request_type,
            TestItemServerProtocol.RunTestItemsRequestParams(
                mode = ps.env.mode,
                coverageRootUris = something(ps.coverage_root_uris, missing),
                testItems = TestItemServerProtocol.RunTestItem[
                    TestItemServerProtocol.RunTestItem(
                        id = i.id,
                        uri = i.uri,
                        name = i.label,
                        packageName = i.package_name,
                        packageUri = i.package_uri,
                        useDefaultUsings = i.option_default_imports,
                        testSetups = i.test_setups,
                        line = i.code_line,
                        column = i.code_column,
                        code = i.code,
                        skip = _skip_source(i.option_skip),
                        timeoutMs = get(timeouts_ms, i.id, missing),
                    ) for i in items
                ],
            )
        )
    catch err
        if err isa JSONRPC.TransportError
            @debug "Run failed (transport error, likely cancelled)" testprocess_id=ps.id exception=(err, catch_backtrace())
        else
            @warn "Error running testitems" testprocess_id=ps.id exception=(err, catch_backtrace())
            try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal)) catch end
        end
    end
end

function _send_steal!(c::TestItemController, ps::TestProcessState, testitem_ids::Vector{String})
    if ps.endpoint === nothing
        @warn "Cannot steal test items: process has no endpoint" testprocess_id=ps.id
        return
    end
    @async try
        if ps.endpoint === nothing
            @debug "Steal cancelled: endpoint gone before send" testprocess_id=ps.id
            return
        end
        JSONRPC.send(
            ps.endpoint,
            TestItemServerProtocol.testserver_steal_testitems_request_type,
            TestItemServerProtocol.StealTestItemsRequestParams(
                testItemIds = testitem_ids
            )
        )
    catch err
        if err isa JSONRPC.TransportError
            @debug "Steal failed (transport error, likely cancelled)" testprocess_id=ps.id exception=(err, catch_backtrace())
        else
            @warn "Error stealing testitems" testprocess_id=ps.id exception=(err, catch_backtrace())
            try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal)) catch end
        end
    end
end

function _start_revise!(c::TestItemController, ps::TestProcessState, new_env_hash)
    if ps.endpoint === nothing
        @warn "Cannot revise: process has no endpoint" testprocess_id=ps.id
        try put!(c.reactor_channel, TestProcessReviseResultMsg(ps.id, true)) catch end
        return
    end
    @async try
        if ps.endpoint === nothing
            @debug "Revise cancelled: endpoint gone before send" testprocess_id=ps.id
            return
        end
        needs_restart = false

        if new_env_hash != ps.test_env_content_hash
            needs_restart = true
        else
            res = JSONRPC.send(ps.endpoint, TestItemServerProtocol.testserver_revise_request_type, nothing)
            if res == "success"
                needs_restart = false
            elseif res == "failed"
                needs_restart = true
            else
                error("Unexpected revise result: $res")
            end
        end

        ps.test_env_content_hash = new_env_hash
        put!(c.reactor_channel, TestProcessReviseResultMsg(ps.id, needs_restart))
    catch err
        if err isa JSONRPC.TransportError
            @debug "Revise failed (transport error, likely cancelled)" testprocess_id=ps.id exception=(err, catch_backtrace())
        else
            @warn "Error during revise" testprocess_id=ps.id exception=(err, catch_backtrace())
        end
        try put!(c.reactor_channel, TestProcessReviseResultMsg(ps.id, true)) catch end
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Test-run helper functions
# ═══════════════════════════════════════════════════════════════════════════════

function _remove_from_proc_queue!(tr::TestRunState, proc_id::String, testitem_id::String)
    if haskey(tr.testitem_ids_by_proc, proc_id)
        idx = findfirst(isequal(testitem_id), tr.testitem_ids_by_proc[proc_id])
        if idx !== nothing
            deleteat!(tr.testitem_ids_by_proc[proc_id], idx)
        end
    end
end

"""
Is `proc_id` the process currently in charge of running `testitem_id`?

`testitem_ids_by_proc` is the single authority on assignment: it is updated on every
reassignment path (initial chunking, work stealing, redistribution after a process dies,
process-id migration on restart) and pruned by `_remove_from_proc_queue!` as soon as a
result is accepted.

This matters because work stealing is speculative — `_check_stealing!` hands an item to the
thief without waiting for the victim to confirm it gave the item up, and a victim that has
already started the item runs it to completion anyway. Both processes therefore report on
it, and only the owner's messages may be acted on; otherwise a late duplicate resets an
already-resolved item to "running" and its terminal result is dropped, leaving the item
stuck non-terminal in a completed run. Because the item leaves the owner's queue once its
result is accepted, this also makes a repeat result from the *same* process a no-op.
"""
function _owns_testitem(tr::TestRunState, proc_id::String, testitem_id::String)
    return testitem_id in get(tr.testitem_ids_by_proc, proc_id, String[])
end

"""
A duplicate result from a process that no longer owns the item. Expected but rare, and the
only way to measure how often speculative stealing actually causes double execution.
"""
function _log_discarded_result(testitem_id::String, proc_id::String, kind::String)
    @info "Discarding '$(kind)' result for test item '$(testitem_id)' from test process '$(proc_id)', which no longer owns it (duplicate execution after a steal)"
end

"""
The owning process reported a result, but the work unit is gone. With the ownership check
in place this should be unreachable: ownership is stricter than presence in
`remaining_work`. It fires if the two disagree — most plausibly because `_resolve_test_env_id`
matched the wrong `TestEnvironment` when several share identical `ProcessEnv` fields, which
would leave the item unresolvable and hang the run.
"""
function _log_unexpected_missing_work(tr::TestRunState, testitem_id::String, proc_id::String, test_env_id::String, kind::String)
    msg = "Dropping '$(kind)' result for test item '$(testitem_id)' from its owning test process '$(proc_id)': no work unit for env '$(test_env_id)'. This is an internal inconsistency."
    @error msg known_envs=[e.id for e in tr.test_environments] exception=(ErrorException(msg), backtrace())
end

"""
Assert the invariant every consumer relies on: by the time a run reports complete, each of
its test items has produced exactly one terminal callback. Breaking it is what let a run be
reported as completed while one item was still "running".

Diagnostic only — it reports nothing to callbacks and changes no state.
"""
function _check_all_items_reported(tr::TestRunState)
    unreported = [k[1] for k in keys(tr.test_items) if k[1] ∉ tr.reported_items]
    if !isempty(unreported)
        msg = "Test run '$(tr.id)' is completing with $(length(unreported)) test item(s) that never produced a result. Consumers will show them as still running."
        @error msg unreported=sort(unreported) exception=(ErrorException(msg), backtrace())
    end
    return unreported
end

"""
Get items for a ProcessEnv that haven't been assigned to a process yet.

`env_pids` are the processes belonging to `env`, and only those may be consulted for what is
already assigned. `testitem_ids_by_proc` holds bare ids, which are unique only within a
package: with the same package checked out twice, both checkouts mint the same id under
different environments. Unioning across *every* process therefore let one environment's
assignment mask the other's identically-named item, which was then never handed to a process
— `remaining_work` never emptied and the run hung instead of completing.
"""
function _get_unchunked_items(tr::TestRunState, env::ProcessEnv, env_pids)
    assigned = Set{String}()
    for pid in env_pids
        ids = get(tr.testitem_ids_by_proc, pid, nothing)
        ids === nothing || union!(assigned, ids)
    end
    test_env_id = _resolve_test_env_id(tr, env)
    # No package comparison here: `test_items` is keyed by env, and `remaining_work` is too,
    # so both already scope to this environment.
    items = [k[1] for (k, _) in tr.test_items
             if k[2] == test_env_id &&
                haskey(tr.remaining_work, (k[1], test_env_id)) &&
                k[1] ∉ assigned]
    return items
end

function _check_stealing!(c::TestItemController, tr::TestRunState, finished_proc_id::String)
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return
    end

    if !haskey(tr.testitem_ids_by_proc, finished_proc_id)
        return
    end

    remaining_for_proc = length(tr.testitem_ids_by_proc[finished_proc_id])
    pending_stolen = length(get(tr.stolen_ids_by_proc, finished_proc_id, String[]))

    if remaining_for_proc > 0 || pending_stolen > 0
        return
    end

    # This process has nothing left to do — try to steal
    if !haskey(c.test_processes, finished_proc_id)
        return
    end
    ps = c.test_processes[finished_proc_id]

    # Find the env for this process in the testrun
    proc_env = nothing
    procs_in_same_env = String[]
    if tr.procs !== nothing
        for (env, pids) in pairs(tr.procs)
            if finished_proc_id in pids
                proc_env = env
                procs_in_same_env = pids
                break
            end
        end
    end

    if proc_env === nothing
        # Process not in any env for this testrun, return to pool
        put!(c.reactor_channel, ReturnToPoolMsg(finished_proc_id, ps.env))
        return
    end

    @info "Test process '$(finished_proc_id)' finished all assigned test items (package '$(proc_env.package_name)')"

    # Find best steal candidate
    best_candidate_id = nothing
    best_count = 1  # only steal if victim has >1 items

    for candidate_pid in procs_in_same_env
        n = length(get(tr.testitem_ids_by_proc, candidate_pid, String[]))
        if n > best_count
            best_count = n
            best_candidate_id = candidate_pid
        end
    end

    if best_candidate_id === nothing
        # Only return to pool here if the testrun won't be completing immediately
        # (which would return all procs). This avoids duplicate ReturnToPoolMsg.
        pending_stolen = sum(length, values(tr.stolen_ids_by_proc); init=0)
        if !isempty(tr.remaining_work) || pending_stolen > 0
            @info "No work to steal, returning test process '$(finished_proc_id)' to pool"
            put!(c.reactor_channel, ReturnToPoolMsg(finished_proc_id, ps.env))
        end
        return
    end

    # Steal half the items from the end of the victim's queue
    victim_ids = tr.testitem_ids_by_proc[best_candidate_id]
    steal_range = (div(length(victim_ids), 2, RoundUp) + 1):lastindex(victim_ids)
    testitem_ids_to_steal = victim_ids[steal_range]

    @info "Stealing $(length(testitem_ids_to_steal)) test item(s) from process '$(best_candidate_id)' to process '$(finished_proc_id)'"

    deleteat!(victim_ids, steal_range)
    append!(get!(tr.testitem_ids_by_proc, finished_proc_id, String[]), testitem_ids_to_steal)

    if best_candidate_id in tr.items_dispatched_to_procs
        for id in testitem_ids_to_steal
            push!(get!(tr.stolen_ids_by_proc, best_candidate_id, String[]), id)
        end

        if haskey(c.test_processes, best_candidate_id)
            victim_ps = c.test_processes[best_candidate_id]
            _send_steal!(c, victim_ps, testitem_ids_to_steal)
        end
    end

    # Send items to thief
    items_to_run = _items_for(tr, _resolve_test_env_id(tr, ps.env), testitem_ids_to_steal)
    _send_run_testitems!(c, ps, items_to_run)
    return
end

function _check_testrun_complete!(c::TestItemController, tr::TestRunState)
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return
    end

    remaining = length(tr.remaining_work)
    pending_stolen = sum(length, values(tr.stolen_ids_by_proc); init=0)

    if remaining == 0 && pending_stolen == 0
        coverage_results = nothing
        if !isempty(tr.coverage)
            coverage_results = map(CoverageTools.merge_coverage_counts(tr.coverage)) do i
                FileCoverage(
                    filepath2uri(i.filename),
                    i.coverage
                )
            end
        end

        @info "Test run '$(tr.id)' completed"
        _check_all_items_reported(tr)
        transition!(tr.fsm, TestRunCompleted; reason="all items done")

        # Return all processes to pool
        if tr.procs !== nothing
            for pid in Iterators.flatten(values(tr.procs))
                if haskey(c.test_processes, pid)
                    ps = c.test_processes[pid]
                    put!(c.reactor_channel, ReturnToPoolMsg(pid, ps.env))
                end
            end
        end

        _signal_testrun_completion!(tr, coverage_results)
    else
        @debug "$(remaining) test item(s) remaining ($(pending_stolen) pending stolen confirmation(s))"
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# execute_testrun — thin wrapper, no callbacks in signature
# ═══════════════════════════════════════════════════════════════════════════════

"""
    execute_testrun(controller, testrun_id, test_environments, test_items, work_units, test_setups, max_processes, token; coverage_root_uris=nothing) -> Union{Nothing,Vector{FileCoverage}}

Submit a test run and block until it completes (or is cancelled).

The controller acquires processes from its pool (launching new ones as needed),
assigns work units to them, and reports progress through the callbacks. When all
work units have finished, the function returns collected coverage data (if the
environments use `"Coverage"` mode) or `nothing`.

# Arguments
- `controller::TestItemController` — a running controller (its reactor loop must be active).
- `testrun_id::String` — unique identifier for this run.
- `test_environments::Vector{TestEnvironment}` — Julia process configurations.
- `test_items::Vector{TestItemDetail}` — metadata for every test item referenced by `work_units`.
- `work_units::Vector{TestRunItem}` — the (test item, environment) pairs to execute.
- `test_setups::Vector{TestSetupDetail}` — setup/module blocks needed by the test items.
- `max_processes::Int` — upper bound on the number of concurrent child processes.
- `token` — a `CancellationToken` (or `nothing`) that can cancel the entire run.

# Keyword arguments
- `coverage_root_uris` — if set, only collect coverage for files under these URI prefixes.
"""
function execute_testrun(
    controller::TestItemController,
    testrun_id::String,
    test_environments::Vector{TestEnvironment},
    test_items::Vector{TestItemDetail},
    work_units::Vector{TestRunItem},
    test_setups::Vector{TestSetupDetail},
    max_processes::Int,
    token;
    coverage_root_uris::Union{Nothing,Vector{String}}=nothing,
    gc_between_testitems::Union{Nothing,Bool}=nothing,
    memory_threshold::Union{Nothing,Float64}=nothing)

    @info "Creating new test run '$(testrun_id)' with $(length(test_items)) test item(s) and $(length(test_environments)) environment(s)"

    _assert_addressable_items(test_items)

    # Build TestRunState
    tr = TestRunState(
        testrun_id,
        test_environments,
        test_items,
        work_units,
        [
            TestSetupDetail(i.package_uri, i.name, i.kind, i.uri, i.line, i.column, i.code)
            for i in test_setups
        ],
        max_processes;
        coverage_root_uris = coverage_root_uris,
        token = token,
        memory_threshold = memory_threshold
    )

    # Register cancellation bridge
    testrun_cancel_registration = nothing
    if token !== nothing
        testrun_cancel_registration = CancellationTokens.register(token) do
            try put!(controller.reactor_channel, TestRunCancelledMsg(testrun_id)) catch end
        end
    end

    if isempty(test_items)
        @warn "No valid test items to run"
        if testrun_cancel_registration !== nothing
            try close(testrun_cancel_registration) catch end
        end
        return nothing
    end

    # Build environment mapping (ProcessEnv → testitem_ids)
    testitem_ids_by_env = Dict{ProcessEnv,Vector{String}}()
    env_content_hash_by_env = Dict{ProcessEnv,Union{Nothing,String}}()
    for env in test_environments
        pe = ProcessEnv(env)
        testitem_ids_by_env[pe] = String[]
        env_content_hash_by_env[pe] = env.env_content_hash
    end
    for wu in work_units
        env = tr.env_by_id[wu.test_env_id]
        pe = ProcessEnv(env)
        push!(testitem_ids_by_env[pe], wu.testitem_id)
    end

    # Calculate process counts
    proc_count_by_env = Dict{ProcessEnv,Int}()
    for (k, v) in pairs(testitem_ids_by_env)
        as_share = length(v) / length(test_items)
        n_procs = max(1, min(floor(Int, max_processes * as_share), length(test_items)))
        proc_count_by_env[k] = n_procs
    end

    # Collecting between items only pays for itself when memory is contended, which in
    # practice means more than one test process — so that is the default, matching
    # ReTestItems' `gc_between_testitems`.
    tr.gc_between_testitems = gc_between_testitems === nothing ?
        sum(values(proc_count_by_env), init=0) > 1 :
        gc_between_testitems

    # Resolve log_level from the first work unit
    log_level = !isempty(work_units) ? first(work_units).log_level : :Info

    # Register test run with controller
    controller.test_runs[testrun_id] = tr
    transition!(tr.fsm, TestRunWaitingForProcs; reason="requesting procs")

    # Build server-side test setup details
    server_test_setups = [
        TestItemServerProtocol.TestsetupDetails(
            packageUri = i.package_uri,
            name = i.name,
            kind = i.kind,
            uri = i.uri,
            line = i.line,
            column = i.column,
            code = i.code
        ) for i in test_setups
    ]

    # Request processes
    put!(
        controller.reactor_channel,
        GetProcsForTestRunMsg(
            testrun_id,
            proc_count_by_env,
            env_content_hash_by_env,
            server_test_setups,
            coverage_root_uris,
            log_level
        )
    )

    # Wait for completion
    coverage_results = take!(tr.completion_channel)

    @debug "Leaving execute_testrun" testrun_id

    if testrun_cancel_registration !== nothing
        try close(testrun_cancel_registration) catch end
    end

    # Clean up test run state
    delete!(controller.test_runs, testrun_id)

    return coverage_results
end
