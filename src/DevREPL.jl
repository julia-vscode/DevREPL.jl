module DevREPL

# TEMP: regular Pkg deps instead of vendored subtrees (see src/pkg_imports.jl
# and packages/ for the vendored wiring, to be restored once all upstream deps
# support the packagedef format).
using ReplMaker
import ProgressMeter
import TestItemControllers
using TestItemControllers: TestItemController, ControllerCallbacks
using TestItemControllers.CancellationTokens: CancellationTokenSource, CancellationToken,
    cancel, get_token, is_cancellation_requested
using AutoHashEquals: @auto_hash_equals
using JuliaWorkspaces
using JuliaWorkspaces.URIs2: URI, filepath2uri, uri2filepath
using TestItemControllers.JSON
using PrecompileTools: @compile_workload, @setup_workload
using Logging
using Dates
import REPL
import REPL.TerminalMenus
import InteractiveUtils

# ── Logging filter (suppress TestItemControllers below Warn) ──────────

struct ModuleFilterLogger <: AbstractLogger
    wrapped::AbstractLogger
end

Logging.shouldlog(logger::ModuleFilterLogger, level, _module, group, id) =
    Logging.shouldlog(logger.wrapped, level, _module, group, id)
Logging.min_enabled_level(logger::ModuleFilterLogger) = Logging.min_enabled_level(logger.wrapped)
Logging.catch_exceptions(logger::ModuleFilterLogger) = Logging.catch_exceptions(logger.wrapped)

function _in_module_tree(m::Module, root::Module)
    while true
        m === root && return true
        parentmodule(m) === m && return false
        m = parentmodule(m)
    end
end

function Logging.handle_message(logger::ModuleFilterLogger, level, message, _module, group, id, filepath, line; kwargs...)
    # Suppress TestItemControllers logs below Warn
    if level < Logging.Warn && _module isa Module && _in_module_tree(_module, TestItemControllers)
        return nothing
    end
    Logging.handle_message(logger.wrapped, level, message, _module, group, id, filepath, line; kwargs...)
end

# ── Background scheduling ─────────────────────────────────────────────
#
# Nothing long-running may run on the REPL's task. `@async` is *sticky* — it
# pins the new task to the spawning thread, which in a REPL session is thread 1,
# the same thread as the line editor, the REPL backend and every `julia>`
# evaluation. So `@async` is the wrong tool for anything long-running, and the
# helpers below are how such work gets scheduled instead. It survives in exactly
# two places where sticky-to-the-current-thread is the point: registering the
# REPL mode, and the per-run event drain.
#
# Which threadpool depends on what the work *is*, and the two answers differ.
# Measured on Julia 1.12 (see the notes on each helper):
#
#   * Thread 1 owns Julia's libuv event loop. While a CPU-bound task occupies
#     it, every timer and every socket/pipe read in the whole process stalls, no
#     matter which thread they were issued from — `sleep(0.1)` on another thread
#     measured 5.1s behind a 5s spin on thread 1, versus 0.1s behind the same
#     spin on a worker thread. So CPU-heavy work must be guaranteed *off*
#     thread 1, and only `:default` guarantees that: `:interactive` spawns were
#     observed landing on thread 1 whenever it was idle.
#
#   * User parallel code (`Threads.@spawn`, `@threads`) saturates `:default` and
#     never touches `:interactive`. A latency-sensitive listener sitting in
#     `:default` was starved to a median 288-447ms wakeup (max ~1.2s) while user
#     work ran, against 0ms median / ≤1ms max in `:interactive`.
#
# Hence: CPU-bound work to `:default`, the I/O-bound reactor to `:interactive`.
# Both hold with a stock `julia` — no `-t` flag is needed, because the reactor
# is always parked on a channel and so never occupies the thread it sits on.
#
# The one thing this cannot fix is CPU-bound code the *user* runs at `julia>`:
# that occupies thread 1 by definition and stalls the event loop process-wide.
# No threadpool choice reaches it.

"""
    _spawn_reactor(f)

Run `f()` on the `:interactive` threadpool: for tasks that spend their life
blocked on a channel or socket and must wake promptly even while the user's own
parallel code saturates `:default`.

Only for work that is genuinely I/O-bound. Interactive tasks may be scheduled
onto thread 1, so CPU-bound work here would stall the process-wide event loop —
use [`_spawn_bg`](@ref) for that.
"""
function _spawn_reactor(f)
    t = Threads.@spawn :interactive f()
    Base.errormonitor(t)
    return t
end

"""
    _spawn_bg(f)

Run `f()` on the `:default` threadpool and return the task. This is the home for
CPU-bound work, because `:default` never includes thread 1 and so can never
stall the event loop the rest of the session depends on.
"""
function _spawn_bg(f; monitor::Bool=true)
    t = Threads.@spawn :default f()
    monitor && Base.errormonitor(t)
    return t
end

"""
    _await_bg(f)

Run `f()` off the REPL's thread and block until it returns its value. The point
is not concurrency but responsiveness: the REPL task is merely parked on `fetch`
instead of executing the work, so the event loop keeps turning, the prompt still
redraws, and any test run already in flight keeps making progress.

Errors surface exactly as if `f` had run inline, so callers keep their existing
`try`/`catch`. An interrupt abandons the *wait*, not the work — the spawned task
runs on so that its own `finally` cleanup still happens.
"""
function _await_bg(f)
    task = _spawn_bg(f; monitor=false)
    try
        return fetch(task)
    catch err
        err isa TaskFailedException && rethrow(err.task.result)
        rethrow()
    end
end

# ── Public types (inlined from TestItemRunnerCore) ────────────────────

@auto_hash_equals struct RunProfile
    name::String
    coverage::Bool
    env::Dict{String,Any}
end

struct ProcessInfo
    id::String
    package_name::String
    status::String
end

struct TestrunResultMessage
    message::String
    uri::URI
    line::Int
    column::Int
end

struct TestrunResultTestitemProfile
    profile_name::String
    status::Symbol
    duration::Union{Float64,Missing}
    messages::Union{Vector{TestrunResultMessage},Missing}
    output::Union{String,Missing}
end

struct TestrunResultTestitem
    name::String
    uri::URI
    profiles::Vector{TestrunResultTestitemProfile}
end

struct TestrunResultDefinitionError
    message::String
    uri::URI
    line::Int
    column::Int
end

struct TestrunResult
    definition_errors::Vector{TestrunResultDefinitionError}
    testitems::Vector{TestrunResultTestitem}
    process_outputs::Dict{String,String}
end

# ── Per-run context (keyed by testrun_id) ─────────────────────────────

# ── Progress events ───────────────────────────────────────────────────
#
# Controller callbacks run inline on the TestItemControllers reactor task, which
# now lives on a different thread than the REPL. They must therefore neither
# touch shared run state nor write to the terminal. Instead they push one of
# these events, and a single drain task per test run applies them and owns all
# rendering — keeping exactly one writer to both `RunContext` and stdout.

struct TestItemEvent
    kind::Symbol            # :passed, :failed, :errored or :skipped
    testitem_id::String
    test_env_id::String
    messages::Any
    duration::Any
end

struct OutputEvent
    testitem_id::String
    output::String
end

struct ProcessLaunchingEvent end

const ProgressEvent = Union{TestItemEvent,OutputEvent,ProcessLaunchingEvent}

mutable struct RunContext
    testitems_by_id::Dict{String,TestItemControllers.TestItemDetail}
    environments::Vector{RunProfile}
    profiles_by_env_id::Dict{String,RunProfile}
    environment_name::String
    progress_ui::Symbol
    progressbar_next::Function
    count_success::Int
    count_fail::Int
    count_error::Int
    count_skipped::Int
    n_total::Int
    responses::Vector{Any}
    outputs::Dict{String,Vector{String}}
    launch_header_printed::Bool
    events::Channel{ProgressEvent}
    lock::ReentrantLock
end

"""
    emit!(ctx, event)

Push a progress event from the reactor task. Never blocks (the channel is
unbounded) and never throws: a run whose channel has already been closed can
still have late events in flight, and dropping those is correct.
"""
function emit!(ctx::RunContext, event::ProgressEvent)
    try
        put!(ctx.events, event)
    catch
        # Channel closed — the run is already being torn down.
    end
    return nothing
end

# ── Run history ───────────────────────────────────────────────────────

mutable struct TestrunRecord
    id::String
    start_time::Float64
    end_time::Union{Nothing,Float64}
    status::Symbol  # :running, :completed, :cancelled, :errored
    result::Union{Nothing,TestrunResult}
    path::String
    cts::Union{Nothing,CancellationTokenSource}
end

# ── Runner state singleton ────────────────────────────────────────────

mutable struct TestItemRunner
    controller::TestItemController
    lock::ReentrantLock
    run_contexts::Dict{String,RunContext}
    processes::Dict{String,ProcessInfo}
    process_outputs::Dict{String,Vector{String}}
    env_package_names::Dict{String,String}  # test_env_id => package_name
    run_history::Vector{TestrunRecord}
    run_counter::Ref{Int}
    max_history::Int
    reactor_task::Union{Nothing,Task}
end

function TestItemRunner(controller::TestItemController; max_history::Int=20)
    TestItemRunner(
        controller,
        ReentrantLock(),
        Dict{String,RunContext}(),
        Dict{String,ProcessInfo}(),
        Dict{String,Vector{String}}(),
        Dict{String,String}(),
        Vector{TestrunRecord}(),
        Ref(0),
        max_history,
        nothing,
    )
end

const _g_runner = Ref{Union{Nothing,TestItemRunner}}(nothing)
const _g_runner_lock = ReentrantLock()

function get_run_context(testrun_id::String)
    runner = get_runner()
    lock(runner.lock) do
        get(runner.run_contexts, testrun_id, nothing)
    end
end

function get_active_processes()
    runner = get_runner()
    lock(runner.lock) do
        collect(values(runner.processes))
    end
end

function get_run_history()
    runner = get_runner()
    lock(runner.lock) do
        copy(runner.run_history)
    end
end

function get_active_runs()
    runner = get_runner()
    lock(runner.lock) do
        filter(r -> r.status == :running, runner.run_history)
    end
end

function cancel_run(id::String)
    runner = get_runner()
    lock(runner.lock) do
        idx = findfirst(r -> r.id == id || startswith(r.id, id), runner.run_history)
        if idx !== nothing
            rec = runner.run_history[idx]
            if rec.status == :running && rec.cts !== nothing
                cancel(rec.cts)
                return true
            end
        end
        return false
    end
end

function get_last_run_id()
    runner = get_runner()
    lock(runner.lock) do
        isempty(runner.run_history) ? nothing : runner.run_history[1].id
    end
end

function get_run_result(id::String)
    runner = get_runner()
    cached = lock(runner.lock) do
        idx = findfirst(r -> r.id == id, runner.run_history)
        idx === nothing && return nothing
        runner.run_history[idx].result
    end
    cached !== nothing && return cached
    # If still running, build a snapshot from the live RunContext
    ctx = lock(runner.lock) do
        get(runner.run_contexts, id, nothing)
    end
    ctx === nothing && return nothing
    _build_result_from_context(runner, id, ctx)
end

# ── Progress event drain ──────────────────────────────────────────────

"""
    _apply_event!(ctx, event)

Apply one progress event: update run state under `ctx.lock`, then render. Only
ever called from the run's drain task, so it is the single writer to both.
"""
function _apply_event!(ctx::RunContext, ev::TestItemEvent)
    testitem = ctx.testitems_by_id[ev.testitem_id]
    lock(ctx.lock) do
        if ev.kind === :passed
            ctx.count_success += 1
        elseif ev.kind === :failed
            ctx.count_fail += 1
        elseif ev.kind === :errored
            ctx.count_error += 1
        else
            ctx.count_skipped += 1
        end
        push!(ctx.responses, (
            testitem = testitem,
            testenvironment = get(ctx.profiles_by_env_id, ev.test_env_id, ctx.environments[1]),
            result = (status=ev.kind, messages=ev.messages, duration=ev.duration),
        ))
    end

    if ctx.progress_ui == :log
        glyph = ev.kind === :passed ? "✓" : ev.kind === :skipped ? "⊘" : "✗"
        duration_string = ev.duration !== missing ? " ($(ev.duration)ms)" : ""
        println("$glyph $(ctx.environment_name) $(uri2filepath(URI(testitem.uri))):$(testitem.label) → $(ev.kind)$duration_string")
    elseif ctx.progress_ui == :bar
        ctx.progressbar_next()
    end
    return nothing
end

function _apply_event!(ctx::RunContext, ev::OutputEvent)
    lock(ctx.lock) do
        push!(get!(() -> String[], ctx.outputs, ev.testitem_id), ev.output)
    end
    return nothing
end

function _apply_event!(ctx::RunContext, ::ProcessLaunchingEvent)
    ctx.progress_ui == :bar || return nothing
    if !ctx.launch_header_printed
        ctx.launch_header_printed = true
        printstyled("  Launching test processes"; color=:cyan)
    end
    printstyled("."; color=:cyan)
    return nothing
end

"""
    _drain_events!(ctx)

Consume `ctx.events` until it is closed. Runs as its own task for the lifetime
of a test run; `run_tests` closes the channel and waits for this to return
before reading the accumulated results.
"""
function _drain_events!(ctx::RunContext)
    for ev in ctx.events
        try
            _apply_event!(ctx, ev)
        catch err
            err isa InterruptException && rethrow()
            @debug "Failed to apply progress event" exception=(err, catch_backtrace())
        end
    end
    return nothing
end

function _build_result_from_context(runner::TestItemRunner, testrun_id::String, ctx::RunContext)
    # Snapshot under ctx.lock: the drain task may still be appending.
    testitem_outputs, responses = lock(ctx.lock) do
        (Dict(k => copy(v) for (k, v) in ctx.outputs), copy(ctx.responses))
    end
    collected_process_outputs = lock(runner.lock) do
        Dict{String,String}(pid => join(chunks) for (pid, chunks) in runner.process_outputs)
    end
    testitems = TestrunResultTestitem[
        TestrunResultTestitem(
            ti.testitem.label,
            URI(ti.testitem.uri),
            [TestrunResultTestitemProfile(
                ti.testenvironment.name,
                ti.result.status,
                ti.result.duration,
                ti.result.messages === missing ? missing : [TestrunResultMessage(msg.message, msg.uri === nothing ? URI("") : URI(msg.uri), something(msg.line, 0), something(msg.column, 0)) for msg in ti.result.messages],
                haskey(testitem_outputs, ti.testitem.id) ? join(testitem_outputs[ti.testitem.id]) : missing
            )]
        ) for ti in responses
    ]
    TestrunResult(TestrunResultDefinitionError[], testitems, collected_process_outputs)
end

function _prune_history!(runner::TestItemRunner)
    while length(runner.run_history) > runner.max_history
        idx = findlast(r -> r.status != :running, runner.run_history)
        idx === nothing && break
        deleteat!(runner.run_history, idx)
    end
end

function terminate_process(id::String)
    if _g_runner[] !== nothing
        TestItemControllers.terminate_test_process(_g_runner[].controller, id)
    end
end

# ── Runner initialization ─────────────────────────────────────────────

function get_runner()
    _g_runner[] !== nothing && return _g_runner[]
    lock(_g_runner_lock) do
        _g_runner[] !== nothing && return _g_runner[]

        callbacks = TestItemControllers.ControllerCallbacks(
            on_testitem_started = (testrun_id, testitem_id, test_env_id) -> nothing,
            # These run on the reactor task: emit an event and return immediately.
            # All state mutation and rendering happens on the run's drain task.
            on_testitem_passed = (testrun_id, testitem_id, test_env_id, duration) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                emit!(ctx, TestItemEvent(:passed, testitem_id, test_env_id, missing, something(duration, missing)))
            end,
            on_testitem_failed = (testrun_id, testitem_id, test_env_id, messages, duration) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                emit!(ctx, TestItemEvent(:failed, testitem_id, test_env_id, messages, something(duration, missing)))
            end,
            on_testitem_errored = (testrun_id, testitem_id, test_env_id, messages, duration) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                emit!(ctx, TestItemEvent(:errored, testitem_id, test_env_id, messages, something(duration, missing)))
            end,
            on_testitem_skipped = (testrun_id, testitem_id, test_env_id) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                emit!(ctx, TestItemEvent(:skipped, testitem_id, test_env_id, missing, missing))
            end,
            on_append_output = (testrun_id, testitem_id, test_env_id, output) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                testitem_id === nothing && return  # process-level output; captured by on_process_output
                emit!(ctx, OutputEvent(testitem_id, output))
            end,
            on_attach_debugger = (testrun_id, debug_pipename) -> nothing,
            on_process_created = (id, test_env_id) -> begin
                runner = _g_runner[]
                lock(runner.lock) do
                    package_name = get(runner.env_package_names, test_env_id, "")
                    runner.processes[id] = ProcessInfo(id, package_name, "Launching")
                end
            end,
            on_process_terminated = (id) -> begin
                runner = _g_runner[]
                lock(runner.lock) do
                    delete!(runner.processes, id)
                end
            end,
            on_process_status_changed = (id, status) -> begin
                runner = _g_runner[]
                lock(runner.lock) do
                    if haskey(runner.processes, id)
                        old = runner.processes[id]
                        runner.processes[id] = ProcessInfo(old.id, old.package_name, status)
                    end
                end
                if status == "Launching"
                    contexts = lock(runner.lock) do
                        collect(values(runner.run_contexts))
                    end
                    for ctx in contexts
                        emit!(ctx, ProcessLaunchingEvent())
                    end
                end
            end,
            on_process_output = (id, output) -> begin
                runner = _g_runner[]
                lock(runner.lock) do
                    if !haskey(runner.process_outputs, id)
                        runner.process_outputs[id] = String[]
                    end
                    push!(runner.process_outputs[id], output)
                end
            end,
        )

        controller = TestItemController(callbacks)
        runner = TestItemRunner(controller)
        _g_runner[] = runner
        # `:interactive`, so the reactor keeps waking promptly even while the
        # user's own parallel code saturates `:default`. Its `@async` children
        # (the per-process IO tasks) are sticky and follow it onto whichever
        # thread it runs on, so TestItemControllers keeps its single-threaded,
        # lock-free invariant with `reactor_channel` as the only entry point.
        runner.reactor_task = _spawn_reactor() do
            try
                run(runner.controller)
            catch err
                Base.display_error(err, catch_backtrace())
            end
        end

        return runner
    end
end

# ── Main entry point ──────────────────────────────────────────────────

# Renders the caller's description of its filter into the progress line, so a
# run that selects nothing says *why* rather than just reporting zero.
_filter_description(::Nothing) = ""
_filter_description(d::String) = " on $d"

function run_tests(
            path;
            filter=nothing,
            filter_description::Union{Nothing,String}=nothing,
            max_workers::Int=min(Sys.CPU_THREADS, 8),
            timeout=60*5,
            fail_on_detection_error=true,
            return_results=false,
            print_failed_results=true,
            print_summary=true,
            progress_ui=:bar,
            environments=[RunProfile("Default", false, Dict{String,Any}())],
            julia_cmd::String="julia",
            julia_args::Vector{String}=String[],
            token=nothing,
            cancellation_source::Union{Nothing,CancellationTokenSource}=nothing
        )
    if progress_ui == :none
        print_summary = false
        print_failed_results = false
    end

    # Recording the source (not just a token) in the history lets 'test cancel <id>'
    # cancel this run later.
    if token === nothing && cancellation_source !== nothing
        token = get_token(cancellation_source)
    end

    runner = get_runner()
    tic = runner.controller
    runner.run_counter[] += 1
    testrun_id = string(runner.run_counter[])

    record = TestrunRecord(testrun_id, time(), nothing, :running, nothing, string(path), cancellation_source)
    lock(runner.lock) do
        pushfirst!(runner.run_history, record)
        _prune_history!(runner)
    end

    jw = JuliaWorkspaces.workspace_from_folders(([path]))
    _add_active_project!(jw)

    testitems = []
    testerrors = []
    for (uri, items) in pairs(JuliaWorkspaces.get_test_items(jw))
        project_details = JuliaWorkspaces.get_test_env(jw, uri)
        textfile = JuliaWorkspaces.get_text_file(jw, uri)

        for item in items.testitems
            (; line, column) = JuliaWorkspaces.position_at(textfile.content, item.code_range.start)
            push!(testitems, (
                uri=uri,
                line=line,
                column=column,
                code=textfile.content.content[item.code_range],
                env=project_details,
                detail=item),
            )
        end

        for item in items.testerrors
            (; line, column) = JuliaWorkspaces.position_at(textfile.content, item.range.start)
            push!(testerrors,
                (
                    uri=string(uri),
                    line=line,
                    column=column,
                    message=item.message
                )
            )
        end
    end

    responses = []

    if length(testerrors) == 0  || fail_on_detection_error==false
        # Report what detection found *before* filtering. Reporting only the
        # post-filter count makes a filter that matches nothing look identical to
        # a package where detection failed outright.
        n_discovered = length(testitems)
        n_discovered_files = length(unique(i.uri for i in testitems))

        if progress_ui != :none
            printstyled("  Discovered $n_discovered test item(s) in $n_discovered_files file(s)\n"; color=:cyan)
        end

        if filter !== nothing
            cd(path) do
                filter!(i->filter((filename=uri2filepath(i.uri), name=i.detail.name, tags=i.detail.option_tags, package_name=i.env.package_name)), testitems)
            end
            if progress_ui != :none && length(testitems) != n_discovered
                printstyled("  Selected $(length(testitems)) of $n_discovered after filtering$(_filter_description(filter_description))\n"; color=:cyan)
            end
        end

        n_total = length(testitems)*length(environments)

        p = ProgressMeter.Progress(n_total;
            barglyphs=ProgressMeter.BarGlyphs('┣','━','╸',' ','┫'),
            color=:green, enabled=progress_ui==:bar)

        debuglogger = Logging.ConsoleLogger(stderr, Logging.Warn)

        environment_name = environments[1].name

        Logging.with_logger(debuglogger) do

            # Build test environments (one per run profile × package test env),
            # test item details, and the work units pairing them up.
            testitems_to_run_by_id = Dict{String, TestItemControllers.TestItemDetail}()
            test_environments = TestItemControllers.TestEnvironment[]
            profiles_by_env_id = Dict{String,RunProfile}()
            env_id_by_key = Dict{Any,String}()
            work_units = TestItemControllers.TestRunItem[]

            for i in testitems
                textfile = JuliaWorkspaces.get_text_file(jw, i.uri)
                item = i.detail
                pos = JuliaWorkspaces.position_at(textfile.content, item.range.start)
                code_pos = JuliaWorkspaces.position_at(textfile.content, item.code_range.start)
                testitems_to_run_by_id[item.id] = TestItemControllers.TestItemDetail(
                    item.id,
                    string(item.uri),
                    item.name,
                    i.env.package_name,
                    string(i.env.package_uri),
                    item.option_default_imports,
                    string.(item.option_setup),
                    pos.line,
                    pos.column,
                    textfile.content.content[item.code_range],
                    code_pos.line,
                    code_pos.column,
                )

                for profile in environments
                    env_key = (profile.name, i.env.package_uri, i.env.project_uri)
                    env_id = get!(env_id_by_key, env_key) do
                        new_id = "$(testrun_id)-env-$(length(env_id_by_key) + 1)"
                        push!(test_environments, TestItemControllers.TestEnvironment(
                            new_id,
                            julia_cmd,
                            julia_args,
                            nothing,
                            Dict{String,Union{String,Nothing}}(k => v isa AbstractString ? string(v) : v === nothing ? nothing : string(v) for (k, v) in profile.env),
                            profile.coverage ? "Coverage" : "Normal",
                            i.env.package_name,
                            string(i.env.package_uri),
                            i.env.project_uri === nothing ? nothing : string(i.env.project_uri),
                            i.env.env_content_hash === nothing ? nothing : string(i.env.env_content_hash),
                        ))
                        profiles_by_env_id[new_id] = profile
                        new_id
                    end
                    push!(work_units, TestItemControllers.TestRunItem(item.id, env_id, Float64(timeout), :Info))
                end
            end

            lock(runner.lock) do
                for env in test_environments
                    runner.env_package_names[env.id] = env.package_name
                end
            end

            if isempty(testitems_to_run_by_id) && progress_ui != :none
                if filter !== nothing && n_discovered > 0
                    printstyled("  No test item matched the filter"; color=:yellow)
                    println(_filter_description(filter_description), ". Use 'test list' to see what is there.")
                else
                    printstyled("  No test items found in $path.\n"; color=:yellow)
                end
            end

            ctx = RunContext(
                testitems_to_run_by_id,
                environments,
                profiles_by_env_id,
                environment_name,
                progress_ui,
                () -> nothing,
                0, 0, 0, 0,
                n_total,
                responses,
                Dict{String,Vector{String}}(),
                false,
                Channel{ProgressEvent}(Inf),
                ReentrantLock(),
            )

            ctx.progressbar_next = () -> begin
                if ctx.launch_header_printed
                    ctx.launch_header_printed = false
                    println()
                end
                done = ctx.count_success + ctx.count_fail + ctx.count_error + ctx.count_skipped
                if done >= ctx.n_total
                    # Final update — erase the progress bar
                    ProgressMeter.cancel(p, ""; keep=false)
                else
                    parts = String[]
                    ctx.count_success > 0 && push!(parts, "$(ctx.count_success) passed")
                    ctx.count_fail > 0 && push!(parts, "$(ctx.count_fail) failed")
                    ctx.count_error > 0 && push!(parts, "$(ctx.count_error) errored")
                    ctx.count_skipped > 0 && push!(parts, "$(ctx.count_skipped) skipped")
                    detail = isempty(parts) ? "" : " ($(join(parts, ", ")))"
                    ProgressMeter.next!(
                        p,
                        showvalues = [
                            (Symbol("Progress"), "$done/$(ctx.n_total)$detail"),
                        ]
                    )
                end
            end

            lock(runner.lock) do
                runner.run_contexts[testrun_id] = ctx
            end

            # The single consumer of `ctx.events`, and the only writer to run
            # state and the terminal while the run is in flight. `run_tests` is
            # parked inside `execute_testrun` for that whole window, so there is
            # never a second writer. `@async` on purpose: sticky keeps the drain
            # on this task's thread, which the callers above already placed on
            # `:default`, and the reactor stays free to just enqueue events.
            drain_task = @async _drain_events!(ctx)

            ret = try
                TestItemControllers.execute_testrun(
                    tic,
                    testrun_id,
                    test_environments,
                    collect(TestItemControllers.TestItemDetail, values(testitems_to_run_by_id)),
                    work_units,
                    let
                        setups = TestItemControllers.TestSetupDetail[]
                        for (uri, file_info) in pairs(JuliaWorkspaces.get_test_items(jw))
                            project_details = JuliaWorkspaces.get_test_env(jw, uri)
                            project_details.package_uri === nothing && continue
                            textfile = JuliaWorkspaces.get_text_file(jw, uri)
                            for setup in file_info.testsetups
                                push!(setups, TestItemControllers.TestSetupDetail(
                                    string(project_details.package_uri),
                                    string(setup.name),
                                    string(setup.kind),
                                    string(uri),
                                    JuliaWorkspaces.position_at(textfile.content, setup.code_range.start).line,
                                    JuliaWorkspaces.position_at(textfile.content, setup.code_range.start).column,
                                    textfile.content.content[setup.code_range]
                                ))
                            end
                        end
                        setups
                    end,
                    max_workers,
                    token,
                )
            catch err
                @error "TestItemControllers.execute_testrun failed" exception=(err, catch_backtrace())
                rethrow(err)
            finally
                # Stop accepting events and let the drain finish applying the
                # ones already queued, before anything reads the results.
                close(ctx.events)
                try; wait(drain_task); catch; end
                # Safety-net: clear progress bar in case of cancellation/error/zero tests
                try; ProgressMeter.cancel(p, ""; keep=false); catch; end
                try
                    partial = _build_result_from_context(runner, testrun_id, ctx)
                    lock(runner.lock) do
                        idx = findfirst(r -> r.id == testrun_id, runner.run_history)
                        if idx !== nothing && runner.run_history[idx].result === nothing
                            runner.run_history[idx].result = partial
                        end
                    end
                catch
                end
                lock(runner.lock) do
                    delete!(runner.run_contexts, testrun_id)
                end
            end

            if any(env -> env.coverage, environments) && ret !== missing && ret !== nothing
                @info "Coverage data collected but not yet processed"
            end

            count_success = ctx.count_success
            count_fail = ctx.count_fail
            count_error = ctx.count_error
            count_skipped = ctx.count_skipped
            testitem_outputs = ctx.outputs

            if ctx.launch_header_printed
                println()
            end
        end
    else
        count_success = 0
        count_fail = 0
        count_error = 0
        count_skipped = 0
        testitem_outputs = Dict{String,Vector{String}}()
    end

    if print_summary
        println()
        parts = String[]
        length(testerrors) > 0 && push!(parts, "$(length(testerrors)) definition error$(ifelse(length(testerrors)==1,"", "s"))")
        push!(parts, "$(length(responses)) tests ran")
        count_success > 0 && push!(parts, "\e[32m$(count_success) passed\e[0m")
        count_fail > 0 && push!(parts, "\e[31m$(count_fail) failed\e[0m")
        count_error > 0 && push!(parts, "\e[31m$(count_error) errored\e[0m")
        count_skipped > 0 && push!(parts, "$(count_skipped) skipped")
        println(join(parts, ", "), ".")
    end

    if print_failed_results
        for te in testerrors
            println()
            println("Definition error at $(uri2filepath(URI(te.uri))):$(te.line)")
            println("  $(te.message)")
        end
    
        for i in responses
            if i.result.status in (:failed, :errored) 
                println()
                label = i.result.status == :failed ? "FAIL" : "ERROR"
                printstyled("  [$label] $(i.testitem.label)"; color=:red, bold=true)
                if i.result.duration !== missing
                    print(" ($(i.result.duration)ms)")
                end
                println()
                if i.result.messages!==missing                
                    for j in i.result.messages
                        println("    ", replace(j.message, "\n"=>"\n    "))
                    end
                end
            end
        end
    end

    collected_process_outputs = lock(runner.lock) do
        Dict{String,String}(id => join(chunks) for (id, chunks) in runner.process_outputs)
    end

    duplicated_testitems = TestrunResultTestitem[
        TestrunResultTestitem(
            ti.testitem.label,
            URI(ti.testitem.uri),
            [TestrunResultTestitemProfile(
                ti.testenvironment.name,
                ti.result.status,
                ti.result.duration,
                ti.result.messages === missing ? missing : [TestrunResultMessage(msg.message, msg.uri === nothing ? URI("") : URI(msg.uri), something(msg.line, 0), something(msg.column, 0)) for msg in ti.result.messages],
                haskey(testitem_outputs, ti.testitem.id) ? join(testitem_outputs[ti.testitem.id]) : missing
            )]
        ) for ti in responses
    ]

    dedup_dict = Dict{Tuple{String, URI}, TestrunResultTestitem}()
    for ti in duplicated_testitems
        k = (ti.name, ti.uri)
        if haskey(dedup_dict, k)
            append!(dedup_dict[k].profiles, ti.profiles)
        else
            dedup_dict[k] = TestrunResultTestitem(ti.name, ti.uri, copy(ti.profiles))
        end
    end
    deduplicated_testitems = collect(values(dedup_dict))

    typed_results = TestrunResult(
        TestrunResultDefinitionError[TestrunResultDefinitionError(i.message, URI(i.uri), i.line, i.column) for i in testerrors],
        deduplicated_testitems,
        collected_process_outputs,
    )

    lock(runner.lock) do
        idx = findfirst(r -> r.id == testrun_id, runner.run_history)
        if idx !== nothing
            runner.run_history[idx].result = typed_results
            runner.run_history[idx].status = :completed
            runner.run_history[idx].end_time = time()
        end
    end

    return return_results ? typed_results : testrun_id
end

function kill_test_processes()
    lock(_g_runner_lock) do
        runner = _g_runner[]
        runner === nothing && return nothing
        TestItemControllers.shutdown(runner.controller)
        if runner.reactor_task !== nothing
            TestItemControllers.wait_for_shutdown(runner.controller, runner.reactor_task)
            runner.reactor_task = nothing
        end
        # Drop the singleton: this controller's reactor has exited, so anything
        # later pushed onto its channel would never be read and the caller would
        # block forever. `get_runner()` returns the cached runner unconditionally,
        # so leaving it in place bricks every subsequent run.
        _g_runner[] = nothing
        return nothing
    end
end

function kill_test_process(id::String)
    if _g_runner[] !== nothing
        TestItemControllers.terminate_test_process(_g_runner[].controller, id)
    end
end

# ── Active project helper ─────────────────────────────────────────────

function _add_active_project!(jw)
    proj = Base.active_project()
    proj === nothing && return
    # Serves as fallback env and fallback test project; out-of-workspace
    # Project/Manifest files are loaded lazily by JuliaWorkspaces itself.
    JuliaWorkspaces.set_active_project!(jw, filepath2uri(dirname(proj)))
end

# ── Juliaup channel resolution ────────────────────────────────────────

const _juliaup_config = Ref{Union{Nothing,Dict,Symbol}}(nothing)

function _load_juliaup_config()
    _juliaup_config[] !== nothing && return _juliaup_config[]
    try
        output = read(`juliaup api getconfig1`, String)
        _juliaup_config[] = JSON.parse(output)
    catch
        _juliaup_config[] = :unavailable
    end
    return _juliaup_config[]
end

function _resolve_juliaup_channel(channel_name::String)
    config = _load_juliaup_config()
    if config === :unavailable
        error("Juliaup is not available. Install Juliaup or run without +channel.")
    end
    # Search default channel first, then other channels
    default = config["DefaultChannel"]
    if default["Name"] == channel_name
        return (julia_cmd=default["File"], julia_args=String.(default["Args"]), version=default["Version"])
    end
    for ch in config["OtherChannels"]
        if ch["Name"] == channel_name
            return (julia_cmd=ch["File"], julia_args=String.(ch["Args"]), version=ch["Version"])
        end
    end
    error("Juliaup channel '$channel_name' is not installed. Use `juliaup list` to see available channels.")
end

# ── Background run state ──────────────────────────────────────────────

mutable struct BackgroundRun
    task::Task
    cts::CancellationTokenSource
    result::Union{Nothing,TestrunResult}
    error::Union{Nothing,Exception}
    start_time::Float64
end

const _bg_run = Ref{Union{Nothing,BackgroundRun}}(nothing)
const _last_result = Ref{Union{Nothing,TestrunResult}}(nothing)
const _last_run_id = Ref{Union{Nothing,String}}(nothing)
# Last foreground selection: (path=..., run_kwargs=...) for 'test repeat'
const _last_selection = Ref{Any}(nothing)

# ── Argument parsing ──────────────────────────────────────────────────

function parse_args(parts)
    positional = String[]
    kwargs = Dict{Symbol,String}()
    flags = Set{Symbol}()
    for p in parts
        if startswith(p, "--")
            body = p[3:end]
            if contains(body, '=')
                k, v = split(body, '='; limit=2)
                kwargs[Symbol(k)] = v
            else
                push!(flags, Symbol(body))
            end
        else
            push!(positional, p)
        end
    end
    return positional, kwargs, flags
end

# ── Commands ──────────────────────────────────────────────────────────

"""
    _print_test_commands()

The `test` group on its own, so a bare `test` or an unknown subcommand can show
exactly the list of words it would have accepted.
"""
function _print_test_commands()
    printstyled("\n  Running ('t' is a shorthand for 'test'):\n"; bold=true)
    println("  test run [path|name]            Run test items (blocking, ESC to cancel)")
    println("  test run --bg                   Run test items in the background")
    println("  test pick [query] [path]        Fuzzy-pick test items to run interactively")
    println("  test failed                     Rerun only the failing items of the last run")
    println("  test repeat                     Repeat the last test run")
    printstyled("\n  Inspecting:\n"; bold=true)
    println("  test list [path]                List discovered test items (alias: ls)")
    println("  test results [id]               Show results (last run, or run #id; alias: res)")
    println("  test failures                   Browse failures of the last run (jump to editor)")
    println("  test history [--active]         List all test runs")
    println("  test status                     Show background run status (alias: st)")
    println("  test cancel [id]                Cancel background run (or run by id)")
    printstyled("\n  Test processes:\n"; bold=true)
    println("  test procs                      Show active test processes (alias: ps)")
    println("  test kill [process-id]          Kill all or a specific test process")
    println("  test log <process-id>           Show output log for a test process")
    printstyled("\n  Run flags:\n"; bold=true)
    println("  --name=<pattern>                Filter by test item name (substring, case-insensitive)")
    println("  --tags=t1,t2                    Filter by tags")
    println("  --workers=N                     Max parallel workers (default: min(CPU_THREADS,8))")
    println("  --timeout=S                     Timeout in seconds (default: 300)")
    println("  --coverage                      Enable coverage")
    println("  +channel                        Run using a Juliaup channel, e.g. +lts")
    printstyled("\n  Results flags:\n"; bold=true)
    println("  --name=<pattern>                Filter results by test item name")
    println("  --verbose                       Show full per-profile details")
    println("  --output                        Show captured output for test items")
    nothing
end

function cmd_help()
    printstyled("DevREPL commands:\n\n"; bold=true)
    println("  help                            Show this help message")
    _print_test_commands()
    printstyled("\n  Linting and formatting:\n"; bold=true)
    println("  lint [path]                     Lint a folder (respects JuliaLint.toml)")
    println("  format [path]                   Format a file or folder in place")
    println("  format --check [path]           Report what would be reformatted")
    nothing
end

function cmd_list(args)
    positional, kwargs, flags = parse_args(args)
    path = isempty(positional) ? pwd() : positional[1]

    if !isdir(path)
        printstyled("Error: "; color=:red, bold=true)
        println("'$path' is not a directory")
        return nothing
    end

    # Same reasoning as `test pick`: detection is the slow part, rendering is not.
    jw, all_items = _await_bg() do
        w = JuliaWorkspaces.workspace_from_folders([path])
        _add_active_project!(w)
        (w, JuliaWorkspaces.get_test_items(w))
    end

    tag_filter = if haskey(kwargs, :tags)
        Set(Symbol.(split(kwargs[:tags], ',')))
    else
        nothing
    end

    count = 0
    for (uri, items) in pairs(all_items)
        textfile = JuliaWorkspaces.get_text_file(jw, uri)
        filepath = uri2filepath(uri)
        for item in items.testitems
            if tag_filter !== nothing && isempty(intersect(Set(item.option_tags), tag_filter))
                continue
            end
            line = JuliaWorkspaces.position_at(textfile.content, item.code_range.start).line
            tags_str = isempty(item.option_tags) ? "" : " [$(join(item.option_tags, ", "))]"
            printstyled("  $(item.name)"; bold=true)
            print("  $filepath:$line")
            if !isempty(tags_str)
                printstyled(tags_str; color=:cyan)
            end
            println()
            count += 1
        end
    end

    if count == 0
        println("  No test items found.")
    else
        println()
        println("$count test item(s) found.")
    end
    nothing
end

# ── Fuzzy test-item picker ────────────────────────────────────────────

function _collect_testitem_candidates(jw)
    candidates = NamedTuple{(:name, :tags, :filepath, :line),Tuple{String,Vector{Symbol},String,Int}}[]
    for (uri, items) in pairs(JuliaWorkspaces.get_test_items(jw))
        textfile = JuliaWorkspaces.get_text_file(jw, uri)
        filepath = uri2filepath(uri)
        for item in items.testitems
            line = JuliaWorkspaces.position_at(textfile.content, item.range.start).line
            push!(candidates, (name=item.name, tags=item.option_tags, filepath=filepath, line=line))
        end
    end
    return candidates
end

# fzf-style match: all query characters appear in order (case-insensitive).
function _is_subsequence(query::AbstractString, s::AbstractString)
    q = lowercase(query)
    qi = firstindex(q)
    for c in lowercase(s)
        qi > lastindex(q) && break
        if c == q[qi]
            qi = nextind(q, qi)
        end
    end
    return qi > lastindex(q)
end

# Candidates whose name matches the query as a subsequence, ranked by fuzzy
# score; candidates that only match via a substring of their file or tags are
# appended after the name matches.
function _fuzzy_sort(query::AbstractString, candidates)
    isempty(query) && return candidates
    matches = [(c, REPL.fuzzyscore(query, c.name)) for c in candidates if _is_subsequence(query, c.name)]
    sort!(matches, by=x -> x[2], rev=true)
    result = [x[1] for x in matches]
    q = lowercase(query)
    for c in candidates
        c in result && continue
        if contains(lowercase(c.filepath), q) || any(t -> contains(lowercase(string(t)), q), c.tags)
            push!(result, c)
        end
    end
    return result
end

function _candidate_label(c, path)
    tags_str = isempty(c.tags) ? "" : "  [$(join(c.tags, ", "))]"
    file = try
        relpath(c.filepath, path)
    catch
        c.filepath
    end
    return "$(c.name)$(tags_str)  $(file):$(c.line)"
end

function cmd_pick(args)
    _check_bg_completion()

    if !(stdin isa Base.TTY)
        printstyled("Error: "; color=:red, bold=true)
        println("'test pick' needs an interactive terminal.")
        return nothing
    end

    juliaup_channel = nothing
    path = pwd()
    query = ""
    flag_args = SubString{String}[]
    for a in args
        if startswith(a, "+")
            juliaup_channel = String(a[2:end])
        elseif startswith(a, "--")
            push!(flag_args, a)
        elseif isdir(a)
            path = String(a)
        else
            query = String(a)
        end
    end

    # Detection parses the whole folder; keep it off the REPL's thread so the
    # prompt stays live and Ctrl-C works while a large package is scanned.
    candidates = _await_bg() do
        jw = JuliaWorkspaces.workspace_from_folders([path])
        _add_active_project!(jw)
        _collect_testitem_candidates(jw)
    end
    if isempty(candidates)
        println("No test items found in '$path'.")
        return nothing
    end

    candidates = _fuzzy_sort(query, candidates)
    if isempty(candidates)
        println("No test items match '$query'.")
        return nothing
    end

    labels = [_candidate_label(c, path) for c in candidates]
    menu = TerminalMenus.MultiSelectMenu(labels; pagesize=min(12, length(labels)))
    chosen = TerminalMenus.request("Select test items (space: toggle, enter: run):", menu)
    if isempty(chosen)
        println("Nothing selected.")
        return nothing
    end
    selected = candidates[sort!(collect(chosen))]

    local run_kwargs
    try
        _, run_kwargs = _build_run_kwargs(flag_args; juliaup_channel)
    catch e
        printstyled("Error: "; color=:red, bold=true)
        println(e.msg)
        return nothing
    end
    sel_keys = Set((c.filepath, c.name) for c in selected)
    run_kwargs[:filter] = info -> (info.filename, string(info.name)) in sel_keys
    run_kwargs[:filter_description] = "the picked test item(s)"

    printstyled("Running $(length(selected)) selected test item(s)...\n"; color=:cyan)
    return _run_blocking(path, run_kwargs)
end

# ── Rerun and failure browsing ────────────────────────────────────────

function cmd_rerun()
    _check_bg_completion()
    sel = _last_selection[]
    if sel === nothing
        println("No previous test run to repeat.")
        return nothing
    end
    printstyled("Repeating last test run...\n"; color=:cyan)
    return _run_blocking(sel.path, copy(sel.run_kwargs))
end

# The last run's result plus the path it ran on (from the run history).
function _last_result_and_path()
    run_id = _last_run_id[]
    result = run_id === nothing ? _last_result[] : something(get_run_result(run_id), _last_result[], Some(nothing))
    result === nothing && return nothing, nothing
    path = nothing
    if run_id !== nothing
        for r in get_run_history()
            if r.id == run_id
                path = r.path
                break
            end
        end
    end
    if path === nothing && _last_selection[] !== nothing
        path = _last_selection[].path
    end
    return result, path
end

function _failure_entries(result)
    entries = []
    for ti in result.testitems, prof in ti.profiles
        prof.status in (:failed, :errored) || continue
        filepath = uri2filepath(ti.uri)
        line = 1
        if prof.messages !== missing && !isempty(prof.messages)
            m1 = prof.messages[1]
            mpath = try
                p = uri2filepath(m1.uri)
                isempty(p) ? nothing : p
            catch
                nothing
            end
            if mpath !== nothing
                filepath = mpath
                line = max(m1.line, 1)
            end
        end
        push!(entries, (ti=ti, prof=prof, filepath=filepath, line=line))
    end
    return entries
end

function cmd_run_failed()
    _check_bg_completion()
    result, path = _last_result_and_path()
    if result === nothing
        println("No test run results available.")
        return nothing
    end
    failing = Set{Tuple{String,String}}()
    for ti in result.testitems
        if any(p -> p.status in (:failed, :errored), ti.profiles)
            push!(failing, (uri2filepath(ti.uri), ti.name))
        end
    end
    if isempty(failing)
        printstyled("No failed or errored test items in the last run.\n"; color=:green)
        return nothing
    end
    if path === nothing
        path = pwd()
    end

    run_kwargs = _last_selection[] === nothing ? Dict{Symbol,Any}() : copy(_last_selection[].run_kwargs)
    run_kwargs[:filter] = info -> (info.filename, string(info.name)) in failing
    run_kwargs[:filter_description] = "the previous run's failures"

    printstyled("Rerunning $(length(failing)) failing test item(s)...\n"; color=:cyan)
    return _run_blocking(path, run_kwargs)
end

function _print_failure(e)
    println()
    label = e.prof.status == :failed ? "FAIL" : "ERROR"
    printstyled("  [$label] $(e.ti.name)"; color=:red, bold=true)
    e.prof.duration !== missing && print(" ($(e.prof.duration)ms)")
    println()
    println("  at $(e.filepath):$(e.line)")
    if e.prof.messages !== missing
        for m in e.prof.messages
            println()
            println("    ", replace(m.message, "\n" => "\n    "))
        end
    end
    if e.prof.output !== missing && !isempty(strip(e.prof.output))
        println()
        printstyled("  Output:\n"; bold=true)
        println("    ", replace(rstrip(e.prof.output), "\n" => "\n    "))
    end
    println()
end

function cmd_failures()
    _check_bg_completion()
    result, _ = _last_result_and_path()
    if result === nothing
        println("No test run results available.")
        return nothing
    end
    entries = _failure_entries(result)
    if isempty(entries)
        printstyled("No failed or errored test items in the last run.\n"; color=:green)
        return nothing
    end

    if !(stdin isa Base.TTY)
        foreach(_print_failure, entries)
        return nothing
    end

    while true
        labels = ["$(e.ti.name) ($(e.prof.status))  $(e.filepath):$(e.line)" for e in entries]
        push!(labels, "quit")
        menu = TerminalMenus.RadioMenu(labels; pagesize=min(12, length(labels)))
        choice = TerminalMenus.request("Failures in last run:", menu)
        (choice == -1 || choice == length(labels)) && return nothing
        e = entries[choice]
        _print_failure(e)
        action = TerminalMenus.request(
            "Action:",
            TerminalMenus.RadioMenu(["Back to failures", "Open in editor", "Quit"]))
        if action == 2
            try
                InteractiveUtils.edit(e.filepath, e.line)
            catch err
                printstyled("Could not open editor: $err\n"; color=:red)
            end
        elseif action != 1
            return nothing
        end
    end
end

function _build_run_kwargs(args; return_results=false, juliaup_channel::Union{Nothing,String}=nothing)
    positional, kwargs, flags = parse_args(args)
    path = nothing
    name_filter = nothing

    # A positional is a path if it names a directory, otherwise a name filter.
    # This is only safe because subcommand words never reach here — see
    # `_dispatch_test`, which rejects unknown words rather than passing them on.
    for p in positional
        if isdir(p)
            path = p
        else
            name_filter = p
        end
    end
    # The explicit spelling wins, and is the way to filter for a name that
    # happens to be a directory or a subcommand word.
    if haskey(kwargs, :name)
        name_filter = kwargs[:name]
    end
    if path === nothing
        path = pwd()
    end

    run_kwargs = Dict{Symbol,Any}(
        :return_results => return_results,
        :print_failed_results => true,
        :print_summary => true,
        :progress_ui => :bar,
    )

    if juliaup_channel !== nothing
        resolved = _resolve_juliaup_channel(juliaup_channel)
        run_kwargs[:julia_cmd] = resolved.julia_cmd
        run_kwargs[:julia_args] = resolved.julia_args
        printstyled("Using Julia $(resolved.version) (+$(juliaup_channel) channel)\n"; color=:cyan)
    end

    if haskey(kwargs, :workers)
        run_kwargs[:max_workers] = parse(Int, kwargs[:workers])
    end
    if haskey(kwargs, :timeout)
        run_kwargs[:timeout] = parse(Int, kwargs[:timeout])
    end
    if :coverage in flags
        run_kwargs[:environments] = [RunProfile("Default", true, Dict{String,Any}())]
    end

    tag_filter = if haskey(kwargs, :tags)
        Set(Symbol.(split(kwargs[:tags], ',')))
    else
        nothing
    end

    if tag_filter !== nothing || name_filter !== nothing
        run_kwargs[:filter] = function(info)
            if name_filter !== nothing && !contains(lowercase(string(info.name)), lowercase(name_filter))
                return false
            end
            if tag_filter !== nothing && isempty(intersect(Set(info.tags), tag_filter))
                return false
            end
            return true
        end
        parts = String[]
        name_filter !== nothing && push!(parts, "name \"$name_filter\"")
        tag_filter !== nothing && push!(parts, "tags $(join(sort!(string.(collect(tag_filter))), ", "))")
        run_kwargs[:filter_description] = join(parts, " and ")
    end

    return path, run_kwargs
end

function cmd_run(args; juliaup_channel::Union{Nothing,String}=nothing)
    _check_bg_completion()
    local path, run_kwargs
    try
        path, run_kwargs = _build_run_kwargs(args; juliaup_channel)
    catch e
        printstyled("Error: "; color=:red, bold=true)
        println(e.msg)
        return nothing
    end
    return _run_blocking(path, run_kwargs)
end

# Run tests in the foreground with ESC-to-cancel handling. run_kwargs may
# already contain a filter; cancellation and result bookkeeping are added here.
function _run_blocking(path, run_kwargs)
    # Remember the selection so 'test repeat' can replay it (without the
    # run-specific cancellation state).
    _last_selection[] = (path=path, run_kwargs=copy(run_kwargs))

    cts = CancellationTokenSource()
    run_kwargs[:cancellation_source] = cts
    run_kwargs[:return_results] = false
    run_kwargs[:print_failed_results] = true
    run_kwargs[:print_summary] = true

    printstyled("Starting test run...\n"; color=:cyan)

    # Run tests off the REPL's thread so the run keeps progressing regardless of
    # what else the session is doing; this task also owns all progress rendering
    # while the REPL task below does nothing but watch for ESC.
    test_task = _spawn_bg() do
        try
            run_tests(path; run_kwargs...)
        catch e
            e
        end
    end

    cancelled = Ref(false)
    try
        # Try to set terminal to raw mode for ESC detection
        term = nothing
        raw_set = false
        try
            if isdefined(Base, :active_repl) && stdin isa Base.TTY
                term = stdin
                ccall(:jl_tty_set_mode, Int32, (Ptr{Nothing}, Int32), term.handle, Int32(1))  # raw mode
                Base.start_reading(stdin)
                raw_set = true
            end
        catch
            # Fall through — ESC detection won't work but Ctrl+C still will
        end

        try
            while !istaskdone(test_task)
                if raw_set && bytesavailable(stdin) > 0
                    b = read(stdin, UInt8)
                    if b == 0x1b  # ESC
                        cancel(cts)
                        cancelled[] = true
                        printstyled("\nTest run cancelled (ESC).\n"; color=:yellow)
                        break
                    end
                end
                sleep(0.05)
            end
        finally
            if raw_set
                try
                    Base.stop_reading(stdin)
                    ccall(:jl_tty_set_mode, Int32, (Ptr{Nothing}, Int32), term.handle, Int32(0))  # normal mode
                catch
                end
            end
        end

        # Retrieve run ID from return value (run_tests returns testrun_id when return_results=false)
        if !cancelled[]
            raw = try
                fetch(test_task)
            catch e
                e
            end
            if raw isa String
                _last_run_id[] = raw
                result = get_run_result(raw)
                if result !== nothing
                    _last_result[] = result
                end
            elseif raw isa Exception
                # Store run ID even if errored
                last_id = get_last_run_id()
                if last_id !== nothing
                    _last_run_id[] = last_id
                    result = get_run_result(last_id)
                    if result !== nothing
                        _last_result[] = result
                    end
                end
                throw(raw)
            end
        else
            # Still retrieve the run ID even if cancelled
            last_id = get_last_run_id()
            if last_id !== nothing
                _last_run_id[] = last_id
                result = get_run_result(last_id)
                if result !== nothing
                    _last_result[] = result
                end
            end
        end
    catch e
        if e isa InterruptException
            cancel(cts)
            printstyled("\nTest run cancelled.\n"; color=:yellow)
        else
            rethrow()
        end
    end
    nothing
end

function cmd_run_bg(args; juliaup_channel::Union{Nothing,String}=nothing)
    _check_bg_completion()

    if _bg_run[] !== nothing && !istaskdone(_bg_run[].task)
        printstyled("A background run is already active. Use 'test cancel' first.\n"; color=:yellow)
        return nothing
    end

    local path, run_kwargs
    try
        path, run_kwargs = _build_run_kwargs(args; return_results=true, juliaup_channel)
    catch e
        printstyled("Error: "; color=:red, bold=true)
        println(e.msg)
        return nothing
    end
    cts = CancellationTokenSource()
    run_kwargs[:cancellation_source] = cts
    run_kwargs[:progress_ui] = :none
    run_kwargs[:print_summary] = false
    run_kwargs[:print_failed_results] = false

    bg = BackgroundRun(
        _spawn_bg() do
            try
                run_tests(path; run_kwargs...)
            catch e
                e
            end
        end,
        cts,
        nothing,
        nothing,
        time(),
    )

    _spawn_bg() do
        raw = try
            fetch(bg.task)
        catch e
            e
        end
        if raw isa Exception
            bg.error = raw
        elseif raw isa TestrunResult
            bg.result = raw
            _last_result[] = raw
        elseif raw isa String
            # return_results=true returns TestrunResult, but capture run ID too
            _last_run_id[] = raw
            result = get_run_result(raw)
            if result !== nothing
                bg.result = result
                _last_result[] = result
            end
        end
    end

    _bg_run[] = bg
    # Retrieve the run ID (it was just created by run_tests)
    last_id = get_last_run_id()
    if last_id !== nothing
        _last_run_id[] = last_id
    end
    id_str = _last_run_id[] !== nothing ? " #$(_last_run_id[])" : ""
    printstyled("Test run$(id_str) started in background.\n"; color=:green)
    nothing
end

"""
    _print_threading_status()

Report the thread configuration and where the reactor actually landed, so a
misscheduled reactor is visible rather than merely slow.
"""
function _print_threading_status()
    println("Threads: $(Threads.nthreads(:default)) default, $(Threads.nthreads(:interactive)) interactive")
    runner = _g_runner[]
    if runner !== nothing && runner.reactor_task !== nothing
        t = runner.reactor_task
        println("Reactor: :$(Threads.threadpool(t)) pool, $(istaskdone(t) ? "stopped" : "running")")
    end
    return nothing
end

function cmd_status()
    _print_threading_status()
    _check_bg_completion()
    bg = _bg_run[]
    if bg === nothing
        println("No background test run.")
        return nothing
    end

    elapsed = round(time() - bg.start_time; digits=1)
    if istaskdone(bg.task)
        if bg.error !== nothing
            printstyled("Background run errored"; color=:red, bold=true)
            println(" after $(elapsed)s: $(bg.error)")
        else
            printstyled("Background run completed"; color=:green, bold=true)
            println(" in $(elapsed)s. Use 'test results' to see details.")
        end
    else
        printstyled("Background run in progress"; color=:yellow, bold=true)
        println(" ($(elapsed)s elapsed)")

        # Show progress details from live snapshot
        run_id = _last_run_id[]
        if run_id !== nothing
            result = get_run_result(run_id)
            if result !== nothing
                n_passed = 0; n_failed = 0; n_errored = 0; n_skipped = 0
                for ti in result.testitems
                    for prof in ti.profiles
                        if prof.status == :passed;  n_passed += 1
                        elseif prof.status == :failed;  n_failed += 1
                        elseif prof.status == :errored; n_errored += 1
                        elseif prof.status == :skipped; n_skipped += 1
                        end
                    end
                end
                done = n_passed + n_failed + n_errored + n_skipped
                # Try to get total from run history
                history = get_run_history()
                rec = nothing
                for r in history
                    if r.id == run_id
                        rec = r
                        break
                    end
                end

                parts = String[]
                n_passed > 0 && push!(parts, "\e[32m$(n_passed) passed\e[0m")
                n_failed > 0 && push!(parts, "\e[31m$(n_failed) failed\e[0m")
                n_errored > 0 && push!(parts, "\e[31m$(n_errored) errored\e[0m")
                n_skipped > 0 && push!(parts, "$(n_skipped) skipped")
                detail = isempty(parts) ? "" : " — $(join(parts, ", "))"
                println("  Progress: $done completed$detail")
            end
        end
    end
    nothing
end

function cmd_cancel(args=String[])
    if !isempty(args)
        # Cancel by run ID
        id = args[1]
        if cancel_run(id)
            printstyled("Cancel requested for run $id.\n"; color=:yellow)
        else
            println("No active run found with id '$id'.")
        end
        return nothing
    end

    bg = _bg_run[]
    if bg === nothing || istaskdone(bg.task)
        println("No active background run to cancel.")
        return nothing
    end
    cancel(bg.cts)
    printstyled("Background run cancel requested.\n"; color=:yellow)
    nothing
end

function cmd_results(args=String[])
    _check_bg_completion()

    positional, kwargs, flags = parse_args(args)

    name_filter = get(kwargs, :name, nothing)
    show_verbose = :verbose in flags
    show_output = :output in flags

    result = nothing
    run_id = nothing
    run_record = nothing

    if !isempty(positional)
        # results <id> — look up a specific run
        run_id = positional[1]
        history = get_run_history()
        idx = findfirst(r -> r.id == run_id || startswith(r.id, run_id), history)
        if idx === nothing
            println("No run found with id '#$run_id'.")
            return nothing
        end
        run_record = history[idx]
        run_id = run_record.id
        result = get_run_result(run_id)
    else
        # results — show last run
        result = _last_result[]
        run_id = _last_run_id[]
        if result === nothing && run_id !== nothing
            result = get_run_result(run_id)
        end
        if run_id !== nothing
            history = get_run_history()
            idx = findfirst(r -> r.id == run_id, history)
            if idx !== nothing
                run_record = history[idx]
            end
        end
    end

    if result === nothing
        println("No test results available.")
        return nothing
    end

    # Apply name filter
    testitems = if name_filter !== nothing
        _filter_testitems(result.testitems, name_filter)
    else
        result.testitems
    end

    if name_filter !== nothing && isempty(testitems)
        println("No test items matching '$(name_filter)'.")
        return nothing
    end

    # --verbose: show full per-profile details for each item
    if show_verbose
        for ti in testitems
            _print_testitem_details(ti)
        end
        println()
        return nothing
    end

    # --output: show only captured output for each item
    if show_output
        for ti in testitems
            _print_testitem_output(ti)
        end
        return nothing
    end

    # Default summary view
    n_passed = 0; n_failed = 0; n_errored = 0; n_skipped = 0
    for ti in testitems
        for prof in ti.profiles
            if prof.status == :passed;  n_passed += 1
            elseif prof.status == :failed;  n_failed += 1
            elseif prof.status == :errored; n_errored += 1
            elseif prof.status == :skipped; n_skipped += 1
            end
        end
    end
    total = n_passed + n_failed + n_errored + n_skipped

    # Header
    println()
    id_str = run_id !== nothing ? "Run #$run_id: " : ""
    is_active = run_record !== nothing && run_record.status == :running
    duration_str = ""
    if run_record !== nothing && run_record.end_time !== nothing
        dur = round(run_record.end_time - run_record.start_time; digits=1)
        duration_str = " ($dur s)"
    elseif is_active
        dur = round(time() - run_record.start_time; digits=1)
        duration_str = " ($dur s, in progress)"
    end
    filter_str = name_filter !== nothing ? " (filtered: '$(name_filter)')" : ""

    printstyled("$(id_str)$(total) test(s)$duration_str$filter_str"; bold=true)
    print(" — ")
    parts = String[]
    n_passed > 0 && push!(parts, "\e[32m$(n_passed) passed\e[0m")
    n_failed > 0 && push!(parts, "\e[31m$(n_failed) failed\e[0m")
    n_errored > 0 && push!(parts, "\e[31m$(n_errored) errored\e[0m")
    n_skipped > 0 && push!(parts, "$(n_skipped) skipped")
    println(join(parts, ", "))

    if is_active
        printstyled("  (run still in progress, showing results so far)\n"; color=:yellow)
    end

    if name_filter === nothing && !isempty(result.definition_errors)
        printstyled("\nDefinition errors:\n"; color=:red, bold=true)
        for de in result.definition_errors
            println("  $(uri2filepath(de.uri)):$(de.line) — $(de.message)")
        end
    end

    # Show failed/errored details
    for ti in testitems
        for prof in ti.profiles
            if prof.status in (:failed, :errored)
                println()
                label = prof.status == :failed ? "FAIL" : "ERROR"
                printstyled("  [$label] $(ti.name)"; color=:red, bold=true)
                if prof.duration !== missing
                    print(" ($(prof.duration)ms)")
                end
                println()
                if prof.messages !== missing
                    for msg in prof.messages
                        println("    ", replace(msg.message, "\n" => "\n    "))
                    end
                end
            end
        end
    end

    # When all pass, show top 5 slowest tests
    if n_failed == 0 && n_errored == 0 && total > 0
        timed = Tuple{String,Float64}[]
        for ti in testitems
            for prof in ti.profiles
                if prof.duration !== missing
                    push!(timed, (ti.name, prof.duration))
                end
            end
        end
        if !isempty(timed)
            sort!(timed; by=last, rev=true)
            n_show = min(5, length(timed))
            println()
            printstyled("  Slowest tests:\n"; color=:light_black)
            for i in 1:n_show
                name, dur = timed[i]
                printstyled("    $(lpad(string(round(dur; digits=1)), 8))ms"; color=:light_black)
                println("  $name")
            end
        end
    end
    nothing
end

function cmd_kill(args=String[])
    if !isempty(args)
        id = args[1]
        procs = get_active_processes()
        idx = findfirst(p -> p.id == id || startswith(p.id, id), procs)
        if idx === nothing
            println("No active process found matching '$id'.")
            return nothing
        end
        proc = procs[idx]
        kill_test_process(proc.id)
        printstyled("Process $(proc.id) terminated.\n"; color=:yellow)
    else
        kill_test_processes()
        printstyled("All test processes terminated.\n"; color=:yellow)
    end
    nothing
end

function cmd_processes()
    procs = get_active_processes()
    if isempty(procs)
        println("No active test processes.")
        return nothing
    end

    printstyled("Active test processes:\n\n"; bold=true)
    printstyled("  $(rpad("ID", 38))$(rpad("Package", 30))Status\n"; bold=true)
    printstyled("  $(repeat("─", 78))\n"; color=:light_black)
    for p in procs
        status_color = if p.status == "Running"
            :green
        elseif p.status == "Idle"
            :light_black
        elseif p.status in ("Launching", "Activating", "Revising")
            :yellow
        else
            :default
        end
        print("  $(rpad(p.id, 38))$(rpad(p.package_name, 30))")
        printstyled("$(p.status)\n"; color=status_color)
    end
    println()
    println("$(length(procs)) process(es) active.")
    nothing
end
# ── Display helpers ──────────────────────────────────────────────────────

function _filter_testitems(testitems, name_pattern::String)
    pattern_lower = lowercase(name_pattern)
    filter(ti -> contains(lowercase(ti.name), pattern_lower), testitems)
end

function _print_testitem_details(ti)
    printstyled("\n$(ti.name)"; bold=true)
    println("  $(uri2filepath(ti.uri))")

    for prof in ti.profiles
        println()
        status_color = if prof.status == :passed
            :green
        elseif prof.status in (:failed, :errored)
            :red
        elseif prof.status == :skipped
            :light_black
        else
            :default
        end
        printstyled("  [$(prof.profile_name)] $(prof.status)"; color=status_color, bold=true)
        if prof.duration !== missing
            print(" ($(prof.duration)ms)")
        end
        println()

        if prof.messages !== missing
            for msg in prof.messages
                println("    $(uri2filepath(msg.uri)):$(msg.line)")
                println("    ", replace(msg.message, "\n" => "\n    "))
            end
        end

        if prof.output !== missing && !isempty(prof.output)
            printstyled("    Output:\n"; color=:cyan)
            for line in split(prof.output, '\n')
                println("      ", line)
            end
        end
    end
end

function _print_testitem_output(ti)
    printstyled("Output for $(ti.name):\n"; bold=true)
    has_output = false
    for prof in ti.profiles
        if prof.output !== missing && !isempty(prof.output)
            if length(ti.profiles) > 1
                printstyled("  [$(prof.profile_name)]\n"; color=:cyan)
            end
            println(prof.output)
            has_output = true
        end
    end
    if !has_output
        println("  No output recorded for this test item.")
    end
end

function cmd_log(args)
    result = _last_result[]
    if result === nothing
        println("No test results available.")
        return nothing
    end
    if isempty(args)
        println("Usage: test log <process id>")
        return nothing
    end

    id = args[1]
    # Try exact match, then prefix match
    output = get(result.process_outputs, id, nothing)
    if output === nothing
        matches = filter(k -> startswith(k, id), collect(keys(result.process_outputs)))
        if length(matches) == 1
            output = result.process_outputs[matches[1]]
            id = matches[1]
        elseif length(matches) > 1
            printstyled("Multiple processes match '$id':\n"; color=:yellow)
            for m in matches
                println("  $m")
            end
            return nothing
        end
    end

    if output === nothing
        println("No process output found for '$id'.")
        return nothing
    end

    printstyled("Process output for $id:\n"; bold=true)
    println(output)
    nothing
end



function cmd_history(args)
    _, kwargs, flags = parse_args(args)
    history = get_run_history()

    if :active in flags
        history = filter(r -> r.status == :running, history)
    end

    if isempty(history)
        if :active in flags
            println("No active test runs.")
        else
            println("No test runs in history.")
        end
        return nothing
    end

    printstyled("Test runs:\n\n"; bold=true)
    printstyled("  $(rpad("#", 6))$(rpad("Started", 12))$(rpad("Duration", 12))$(rpad("Status", 12))$(rpad("Tests", 10))Path\n"; bold=true)
    printstyled("  $(repeat("─", 76))\n"; color=:light_black)

    for r in history
        started = Dates.format(Dates.unix2datetime(r.start_time), "HH:MM:SS")
        duration = if r.end_time !== nothing
            elapsed = r.end_time - r.start_time
            "$(round(elapsed; digits=1))s"
        elseif r.status == :running
            elapsed = time() - r.start_time
            "$(round(elapsed; digits=1))s…"
        else
            "-"
        end
        status_color = if r.status == :running
            :yellow
        elseif r.status == :completed
            :green
        elseif r.status in (:cancelled, :errored)
            :red
        else
            :default
        end

        # Compute test count summary
        tests_str = "-"
        res = r.result
        if res === nothing && r.status == :running
            res = get_run_result(r.id)
        end
        if res !== nothing
            n = length(res.testitems)
            n_done = sum(length(ti.profiles) for ti in res.testitems; init=0)
            tests_str = "$n_done"
        end

        print("  $(rpad(r.id, 6))$(rpad(started, 12))$(rpad(duration, 12))")
        printstyled("$(rpad(r.status, 12))"; color=status_color)
        print("$(rpad(tests_str, 10))")
        println(r.path)
    end
    println()
    println("$(length(history)) run(s). Use 'test results <id>' to inspect a run.")
    nothing
end
# ── Helpers ───────────────────────────────────────────────────────────

function _check_bg_completion()
    bg = _bg_run[]
    if bg !== nothing && istaskdone(bg.task)
        if bg.result !== nothing && bg.error === nothing
            elapsed = round(time() - bg.start_time; digits=1)
            printstyled("Background run completed in $(elapsed)s. Use 'test results' to see details.\n"; color=:green)
        elseif bg.error !== nothing
            printstyled("Background run errored: $(bg.error)\n"; color=:red)
        end
    end
end

# ── Lint ──────────────────────────────────────────────────────────────

const _LINT_SEVERITY_COLORS = Dict(
    :error => :red,
    :warning => :yellow,
    :information => :cyan,
    :hint => :light_black,
)

# The stable rule id, as named in JuliaLint.toml (falls back to the source
# for diagnostics that predate rule ids) — same convention as julialint.
_lint_rule_id(diag) = diag.code === nothing ? diag.source : string(diag.code)

function cmd_lint(args)
    positional, _, _ = parse_args(args)
    path = isempty(positional) ? pwd() : String(positional[1])
    if !isdir(path)
        printstyled("Error: "; color=:red, bold=true)
        println("'$path' is not a directory")
        return nothing
    end

    printstyled("Analyzing $path...\n"; color=:cyan)
    local jw, all_diagnostics
    try
        # Off the REPL's thread: parsing and diagnostics are the longest blocking
        # work in the package, and running them inline froze the prompt outright.
        # JuliaWorkspaces is `@async`-only internally, and `@async` is sticky, so
        # the whole dynamic-feature task tree follows the workspace onto this
        # thread as one unit. Rendering stays on the REPL task below.
        jw, all_diagnostics = _await_bg() do
            Logging.with_logger(Logging.ConsoleLogger(stderr, Logging.Warn)) do
                w = JuliaWorkspaces.workspace_from_folders([path];
                    dynamic=JuliaWorkspaces.DynamicIndexingOnly,
                    symbolcache_download=true)
                try
                    JuliaWorkspaces.parse_files_blocking(w)
                    JuliaWorkspaces.wait_until_ready(w)
                    (w, JuliaWorkspaces.get_diagnostics_blocking(w))
                finally
                    # Stop the dynamic feature's child processes; a REPL session may
                    # run many lints and must not accumulate reactors.
                    try
                        put!(w.dynamic_feature.in_channel, JuliaWorkspaces.ShutdownMsg())
                    catch
                    end
                end
            end
        end
    catch err
        err isa InterruptException && rethrow()
        printstyled("Error: "; color=:red, bold=true)
        println("lint failed for $path: ", sprint(showerror, err))
        return nothing
    end

    entries = []
    for (uri, diagnostics) in all_diagnostics
        isempty(diagnostics) && continue
        text_file = JuliaWorkspaces.get_text_file(jw, uri)
        abs_path = uri2filepath(uri)
        for diag in diagnostics
            push!(entries, (abs_path, first(diag.range), diag, text_file))
        end
    end
    sort!(entries, by=x -> (x[1], x[2]))

    counts = Dict{Symbol,Int}()
    for (abs_path, _, diag, text_file) in entries
        pos = JuliaWorkspaces.position_at(text_file.content, first(diag.range))
        print("  $abs_path:$(pos.line):$(pos.column): ")
        printstyled(string(diag.severity); color=get(_LINT_SEVERITY_COLORS, diag.severity, :default))
        print(": ", diag.message)
        rule = _lint_rule_id(diag)
        isempty(rule) || printstyled(" [$rule]"; color=:light_black)
        println()
        counts[diag.severity] = get(counts, diag.severity, 0) + 1
    end

    println()
    if isempty(entries)
        printstyled("No lint findings.\n"; color=:green)
    else
        parts = String[]
        for sev in (:error, :warning, :information, :hint)
            n = get(counts, sev, 0)
            n > 0 && push!(parts, "$n $(sev == :information ? "info" : sev)$(n == 1 ? "" : "s")")
        end
        println(join(parts, ", "), ".")
    end
    nothing
end

# ── Format ────────────────────────────────────────────────────────────

function cmd_format(args)
    positional, _, flags = parse_args(args)
    check = :check in flags
    path = isempty(positional) ? pwd() : String(positional[1])

    target_file = nothing
    if isfile(path)
        target_file = normpath(abspath(path))
        folder = dirname(target_file)
    elseif isdir(path)
        folder = path
    else
        printstyled("Error: "; color=:red, bold=true)
        println("'$path' is not a file or directory")
        return nothing
    end

    # Formatting is purely syntactic, so no dynamic environment analysis is
    # needed — same as juliaformat. Parsing the folder and computing the edits is
    # the slow part, so it runs off the REPL's thread; the loop below only
    # renders and writes.
    outcomes = _await_bg() do
        jw = JuliaWorkspaces.workspace_from_folders([folder])
        target_uris = collect(JuliaWorkspaces.get_julia_files(jw))
        if target_file !== nothing
            # Case-insensitive comparison: on Windows uri2filepath yields a
            # lowercase drive letter while abspath keeps the typed case.
            wanted = lowercase(target_file)
            filter!(uri -> begin
                p = uri2filepath(uri)
                p !== nothing && lowercase(normpath(abspath(p))) == wanted
            end, target_uris)
        end
        sort!(target_uris, by=uri -> something(uri2filepath(uri), ""))

        map(target_uris) do uri
            fp = uri2filepath(uri)
            JuliaWorkspaces.is_format_excluded(jw, uri) && return (fp, :skipped, nothing)
            edit = try
                JuliaWorkspaces.get_format_edits(jw, uri)
            catch err
                return (fp, :error, err)
            end
            edit === nothing && return (fp, :skipped, nothing)
            isempty(edit.edits) && return (fp, :unchanged, nothing)
            return (fp, :reformat, edit.edits[1].new_text)
        end
    end

    if isempty(outcomes)
        printstyled("No Julia files found to format.\n"; color=:yellow)
        return nothing
    end

    n_reformatted = 0
    n_unchanged = 0
    n_errors = 0
    n_skipped = 0

    for (fp, outcome, payload) in outcomes
        if outcome === :error
            n_errors += 1
            printstyled("  error"; color=:red, bold=true)
            println(": failed to format $fp: ", sprint(showerror, payload))
            continue
        elseif outcome === :skipped
            n_skipped += 1
            continue
        elseif outcome === :unchanged
            n_unchanged += 1
            continue
        end

        n_reformatted += 1
        if check
            println("  would reformat $fp")
        else
            try
                open(fp, "w") do io
                    print(io, payload)
                end
            catch err
                n_reformatted -= 1
                n_errors += 1
                printstyled("  error"; color=:red, bold=true)
                println(": failed to write $fp: ", sprint(showerror, err))
                continue
            end
            printstyled("  formatted"; color=:cyan)
            println(" $fp")
        end
    end

    parts = String[]
    if check
        if n_reformatted > 0
            push!(parts, "$n_reformatted file$(n_reformatted == 1 ? "" : "s") would be reformatted")
            push!(parts, "$n_unchanged already formatted")
        else
            push!(parts, "all $n_unchanged file$(n_unchanged == 1 ? "" : "s") already formatted")
        end
    else
        n_reformatted > 0 && push!(parts, "$n_reformatted reformatted")
        n_unchanged > 0 && push!(parts, "$n_unchanged unchanged")
    end
    n_errors > 0 && push!(parts, "$n_errors error$(n_errors == 1 ? "" : "s")")
    n_skipped > 0 && push!(parts, "$n_skipped excluded")
    isempty(parts) || println(join(parts, ", "), ".")
    nothing
end

# ── Tab completion ────────────────────────────────────────────────────

struct DevREPLCompletionProvider <: REPL.LineEdit.CompletionProvider end

const _TOP_COMMANDS = ["test", "lint", "format", "help"]
const _TEST_SUBCOMMANDS = ["run", "pick", "failed", "repeat", "list", "results",
    "failures", "history", "status", "cancel", "procs", "kill", "log"]
const _TEST_RUN_FLAGS = ["--name=", "--tags=", "--workers=", "--timeout=", "--coverage", "--bg"]
const _RESULTS_FLAGS = ["--name=", "--verbose", "--output"]

function _juliaup_channel_names()
    config = _load_juliaup_config()
    config === :unavailable && return String[]
    names = String[]
    try
        push!(names, config["DefaultChannel"]["Name"])
        for ch in config["OtherChannels"]
            push!(names, ch["Name"])
        end
    catch
    end
    return names
end

function _complete_dirs(prefix::AbstractString)
    dir, base = splitdir(prefix)
    lookin = isempty(dir) ? pwd() : dir
    isdir(lookin) || return String[]
    out = String[]
    sep = Base.Filesystem.path_separator
    for name in try readdir(lookin) catch; return String[] end
        startswith(name, base) || continue
        isdir(joinpath(lookin, name)) || continue
        push!(out, (isempty(dir) ? name : joinpath(dir, name)) * sep)
    end
    return out
end

# Completion candidates for the token being typed, given the text before the
# cursor. Returns (matches, token-to-replace).
function _devrepl_completions(partial::AbstractString)
    tokens = split(partial)
    ends_with_space = isempty(partial) || isspace(partial[end])
    cur = ends_with_space ? "" : String(last(tokens))
    prev = ends_with_space ? String.(tokens) : String.(tokens[1:end-1])

    cands = String[]
    if isempty(prev)
        cands = _TOP_COMMANDS
    else
        cmd = lowercase(prev[1])
        cmd == "t" && (cmd = "test")
        if cmd == "test"
            sub = length(prev) >= 2 ? lowercase(prev[2]) : nothing
            if startswith(cur, "+")
                cands = ["+" * n for n in _juliaup_channel_names()]
            elseif sub === nothing
                # A subcommand is required, so only subcommands complete here.
                cands = _TEST_SUBCOMMANDS
            elseif sub == "run"
                cands = startswith(cur, "--") ? _TEST_RUN_FLAGS : _complete_dirs(cur)
            elseif sub in ("results", "res")
                cands = _RESULTS_FLAGS
            elseif sub == "history"
                cands = ["--active"]
            elseif sub in ("list", "ls", "pick")
                cands = startswith(cur, "--") ? ["--tags="] : _complete_dirs(cur)
            else
                cands = String[]
            end
        elseif cmd == "lint"
            cands = _complete_dirs(cur)
        elseif cmd == "format"
            cands = startswith(cur, "--") ? ["--check"] : _complete_dirs(cur)
        end
    end

    matches = sort!(filter(c -> startswith(c, cur), unique(cands)))
    return matches, cur
end

function REPL.LineEdit.complete_line(::DevREPLCompletionProvider, s; hint::Bool=false)
    partial = REPL.beforecursor(REPL.LineEdit.buffer(s))
    matches, cur = _devrepl_completions(partial)
    return matches, cur, !isempty(matches)
end

# ── REPL parser ───────────────────────────────────────────────────────

function repl_parser(input::String)
    input = strip(input)
    isempty(input) && return nothing

    parts = split(input)
    cmd = lowercase(parts[1])
    args = parts[2:end]

    if cmd == "help" || cmd == "?"
        return cmd_help()
    elseif cmd == "test" || cmd == "t"
        return _dispatch_test(args)
    elseif cmd == "lint"
        return cmd_lint(args)
    elseif cmd == "format"
        return cmd_format(args)
    else
        printstyled("Unknown command: $cmd\n"; color=:red)
        println("Type 'help' for available commands.")
        return nothing
    end
end

"""
    _dispatch_run(args)

Shared tail of `test run`. Pulls out `+channel` and `--bg`, then hands the rest
to the blocking or background runner. `args` here never contains a subcommand
word — the caller has already consumed it.
"""
function _dispatch_run(args)
    juliaup_channel = nothing
    background = false
    remaining_args = SubString{String}[]
    for a in args
        if startswith(a, "+")
            juliaup_channel = String(a[2:end])
        elseif lowercase(a) == "--bg"
            background = true
        else
            push!(remaining_args, a)
        end
    end
    return background ? cmd_run_bg(remaining_args; juliaup_channel) :
                        cmd_run(remaining_args; juliaup_channel)
end

# Every word accepted after `test`. There is deliberately no catch-all: an
# unrecognized word is an error, never a name filter. Letting unknown words fall
# through to the runner is what made `test run` silently match zero test items
# for as long as `run` itself was missing from this list.
function _dispatch_test(args)
    sub = isempty(args) ? "" : lowercase(args[1])
    rest = isempty(args) ? SubString{String}[] : args[2:end]

    if sub == "run"
        return _dispatch_run(rest)
    elseif sub == "pick"
        return cmd_pick(rest)
    elseif sub == "repeat"
        return cmd_rerun()
    elseif sub == "failed"
        return cmd_run_failed()
    elseif sub == "failures"
        return cmd_failures()
    elseif sub in ("list", "ls")
        return cmd_list(rest)
    elseif sub in ("status", "st")
        return cmd_status()
    elseif sub == "cancel"
        return cmd_cancel(rest)
    elseif sub in ("results", "res")
        return cmd_results(rest)
    elseif sub == "log"
        return cmd_log(rest)
    elseif sub == "history"
        return cmd_history(rest)
    elseif sub in ("procs", "ps")
        return cmd_processes()
    elseif sub == "kill"
        return cmd_kill(rest)
    elseif sub == ""
        println("'test' needs a subcommand.")
        _print_test_commands()
        return nothing
    else
        printstyled("Unknown test command: $sub\n"; color=:red)
        _print_test_commands()
        return nothing
    end
end

# ── Precompilation workload ───────────────────────────────────────────

@setup_workload begin
    precompiledata_path = joinpath(@__DIR__, "..", "precompiledata")

    @compile_workload begin
        run_tests(
            precompiledata_path;
            return_results=true,
            print_summary=false,
            print_failed_results=false,
            progress_ui=:log,
            max_workers=1,
            timeout=60,
            fail_on_detection_error=false,
        )
        kill_test_processes()
    end
end

# ── REPL mode registration ───────────────────────────────────────────

function _register_repl_mode()
    initrepl(
        repl_parser;
        prompt_text="dev> ",
        prompt_color=:yellow,
        start_key=')',
        mode_name="Dev",
        sticky_mode=true,
        valid_input_checker=s -> true,
        completion_provider=DevREPLCompletionProvider(),
    )
end

function __init__()
    # Precompilation leaves a stale runner with dead reactor/shutdown controller; reset it
    _g_runner[] = nothing

    global_logger(ModuleFilterLogger(global_logger()))

    if isdefined(Base, :active_repl)
        _register_repl_mode()
    else
        atreplinit() do repl
            @async _register_repl_mode()
        end
    end
end

end # module DevREPL
