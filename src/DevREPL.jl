module DevREPL

# TEMP: regular Pkg deps instead of vendored subtrees (see src/pkg_imports.jl
# and packages/ for the vendored wiring, to be restored once all upstream deps
# support the packagedef format).
using ReplMaker
import ProgressMeter
import TestItemRuns
using TestItemRuns: TestSession, TestRun, RunProfile, ProcessInfo, discover_testitems, select,
    run_async!, cancel!, snapshot, run_progress, list_runs, get_run, list_processes,
    terminate_process!, terminate_all_processes!, process_output, subscribe!, unsubscribe!,
    RunEvent, RunStarted, TestItemFinished, OutputAppended, ProcessStatusChanged, RunFinished,
    TestrunResult, TestrunResultTestitem, TestrunResultTestitemProfile, TestrunResultMessage,
    TestrunResultDefinitionError
using TestItemRuns.CancellationTokens: CancellationTokenSource, CancellationToken,
    cancel, get_token, is_cancellation_requested
using JuliaWorkspaces
using JuliaWorkspaces.URIs2: URI, filepath2uri, uri2filepath
import JSON
using PrecompileTools: @compile_workload, @setup_workload
using Logging
using Dates
import REPL
import REPL.TerminalMenus
import InteractiveUtils

# ── Logging filter (suppress TestItemControllers below Warn) ──────────

const TestItemControllers = TestItemRuns.TestItemControllers

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
# Hence: CPU-bound work to `:default`, the I/O-bound reactor to `:interactive`
# (which is where `TestSession(; reactor_pool=:interactive)` puts it).
# Both hold with a stock `julia` — no `-t` flag is needed, because the reactor
# is always parked on a channel and so never occupies the thread it sits on.
#
# The one thing this cannot fix is CPU-bound code the *user* runs at `julia>`:
# that occupies thread 1 by definition and stalls the event loop process-wide.
# No threadpool choice reaches it.

# The I/O-bound TestItemControllers reactor is placed on `:interactive` by
# `TestSession(; reactor_pool=:interactive)`.

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

# ── Types ─────────────────────────────────────────────────────────────
#
# Test discovery, execution, run history, process management and results all
# come from TestItemRuns; DevREPL adds the REPL presentation on top. `RunProfile`,
# `ProcessInfo`, `TestRun` and the `TestrunResult*` types are TestItemRuns' own.

# `uri2filepath` on the string uris carried by TestItemRuns' results.
_fp(uri::AbstractString) = something(uri2filepath(URI(uri)), String(uri))
_fp(uri::URI) = something(uri2filepath(uri), string(uri))

"""
    RunPresentation

Everything a run says to the terminal, in one place and mutable, so it can change
while the run is in flight. That is what makes detaching a running test run to
the background — and attaching to one later — possible: both are just a change of
presentation on a run that keeps going either way.

`mode` is `:bar`, `:log` or `:none`. `render` draws one unit of progress and is
rebuilt on attach, since a `ProgressMeter.Progress` bakes in `enabled` and the
terminal width at construction.
"""
mutable struct RunPresentation
    mode::Symbol
    show_summary::Bool
    show_failures::Bool
    render::Function
    launch_header_printed::Bool
end

RunPresentation(mode::Symbol; show_summary::Bool=false, show_failures::Bool=false) =
    RunPresentation(mode, show_summary, show_failures, () -> nothing, false)

"Silence a run without stopping it — used when detaching to the background."
function detach!(pres::RunPresentation)
    pres.mode = :none
    pres.show_summary = false
    pres.show_failures = false
    return pres
end

_seconds_between(a::DateTime, b::DateTime) = Dates.value(b - a) / 1000

# The presentation of a run, stored on the run itself so `test attach` can find it.
_presentation(run::TestRun) = get(run.metadata, "pres", nothing)::Union{Nothing,RunPresentation}
_run_path(run::TestRun) = get(run.metadata, "path", "")::String

"""
    RunRenderer

The event sink of one run. It reads the run's `RunPresentation` on every event, so
a detach from the REPL task (or an attach with a fresh progress bar) takes effect
on the next event without touching the run.
"""
struct RunRenderer
    run::TestRun
    pres::RunPresentation
end

(r::RunRenderer)(::RunEvent) = nothing

function (r::RunRenderer)(ev::TestItemFinished)
    # Read the mode once: a detach from the REPL task can flip it underneath us.
    mode = r.pres.mode
    if mode === :log
        glyph = ev.status === :passed ? "✓" : ev.status === :skipped ? "⊘" : "✗"
        duration_string = ev.duration !== nothing ? " ($(ev.duration)ms)" : ""
        println("$glyph $(ev.profile) $(ev.item.filename):$(ev.item.name) → $(ev.status)$duration_string")
    elseif mode === :bar
        r.pres.render()
    end
    return nothing
end

function (r::RunRenderer)(ev::ProcessStatusChanged)
    ev.status == "Launching" || return nothing
    r.pres.mode === :bar || return nothing
    if !r.pres.launch_header_printed
        r.pres.launch_header_printed = true
        printstyled("  Launching test processes"; color=:cyan)
    end
    printstyled("."; color=:cyan)
    return nothing
end

# ── Session singleton ─────────────────────────────────────────────────

const _g_session = Ref{Union{Nothing,TestSession}}(nothing)
const _g_session_lock = ReentrantLock()
const _run_counter = Ref(0)

"""
    get_session() -> TestSession

The process-wide test session: one controller and one pool of test processes,
reused across `test run` invocations. Created lazily; `kill_test_processes` empties
the pool but keeps the session.
"""
function get_session()
    s = _g_session[]
    s !== nothing && isopen(s) && return s
    lock(_g_session_lock) do
        s = _g_session[]
        s !== nothing && isopen(s) && return s
        # `:interactive`, so the reactor keeps waking promptly even while the
        # user's own parallel code saturates `:default`.
        s = TestSession(; reactor_pool=:interactive, max_history=20)
        _g_session[] = s
        return s
    end
end

get_active_processes() = list_processes(get_session())

get_run_history() = list_runs(get_session())

get_active_runs() = TestRun[r for r in list_runs(get_session()) if r.status == :running]

function _find_run(id::AbstractString)
    try
        return get_run(get_session(), id)
    catch err
        err isa ArgumentError && return nothing   # ambiguous prefix
        rethrow()
    end
end

function cancel_run(id::String)
    run = _find_run(id)
    (run === nothing || run.status != :running) && return false
    cancel!(run)
    return true
end

function get_last_run_id()
    history = get_run_history()
    isempty(history) ? nothing : history[1].id
end

"The result of a run: final once it finished, a live snapshot while it is running."
function get_run_result(id::String)
    run = _find_run(id)
    run === nothing && return nothing
    return snapshot(run)
end

terminate_process(id::String) = terminate_process!(get_session(), id)

# ── Main entry point ──────────────────────────────────────────────────

# Renders the caller's description of its filter into the progress line, so a
# run that selects nothing says *why* rather than just reporting zero.
_filter_description(::Nothing) = ""
_filter_description(d::String) = " on $d"

"""
    _make_progress_bar(n_total; start=0)

Build the run's progress bar. `start` lets `test attach` pick a run up mid-flight
at the count it has already reached.

`barlen` is given explicitly because ProgressMeter's default (`nothing`) expands
the bar to the full terminal width — `displaysize(output)[2] - length(desc) - 29`
— which is far wider than it needs to be. The cap still shrinks on narrow
terminals so the line never wraps.

Always constructed enabled: whether anything is drawn is decided per event by
`RunPresentation.mode`, which can change mid-run, whereas `enabled` is baked in
here and could not.
"""
function _make_progress_bar(n_total::Integer; start::Integer=0)
    barlen = clamp(displaysize(stderr)[2] - 40, 10, 40)
    return ProgressMeter.Progress(n_total;
        start=start,
        barlen=barlen,
        barglyphs=ProgressMeter.BarGlyphs('┣','━','╸',' ','┫'),
        color=:green, enabled=true)
end

"""
    _bar_renderer(run, pres, p)

The `:bar` renderer: one call per completed test item. Kept separate from the
presentation so `test attach` can install a fresh one over a new bar.
"""
function _bar_renderer(run::TestRun, pres::RunPresentation, p)
    return () -> begin
        if pres.launch_header_printed
            pres.launch_header_printed = false
            println()
        end
        prog = run_progress(run)
        if prog.done >= prog.total
            # Final update — erase the progress bar
            ProgressMeter.cancel(p, ""; keep=false)
        else
            parts = String[]
            prog.passed > 0 && push!(parts, "$(prog.passed) passed")
            prog.failed > 0 && push!(parts, "$(prog.failed) failed")
            prog.errored > 0 && push!(parts, "$(prog.errored) errored")
            prog.skipped > 0 && push!(parts, "$(prog.skipped) skipped")
            detail = isempty(parts) ? "" : " ($(join(parts, ", ")))"
            ProgressMeter.next!(
                p,
                showvalues = [
                    (Symbol("Progress"), "$(prog.done)/$(prog.total)$detail"),
                ]
            )
        end
    end
end

"""
    run_tests(path; kwargs...)

Run the test items under `path` on the shared session and return the run id (or
the `TestrunResult` with `return_results=true`).

`on_registered` is how the id becomes known before the run finishes: it is minted
before any work starts, and background bookkeeping needs it up front rather than
reverse-engineered from history order afterwards.
"""
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
            presentation::Union{Nothing,RunPresentation}=nothing,
            environments=[RunProfile("Default", false, Dict{String,Any}())],
            julia_cmd::String="julia",
            julia_args::Vector{String}=String[],
            token=nothing,
            on_registered=nothing,
            cancellation_source::Union{Nothing,CancellationTokenSource}=nothing
        )
    if progress_ui == :none
        print_summary = false
        print_failed_results = false
    end

    # When the caller supplies a presentation it keeps a reference, which is how
    # the REPL task silences a run it is detaching to the background — the run
    # itself carries on untouched.
    pres = presentation === nothing ?
        RunPresentation(progress_ui; show_summary=print_summary, show_failures=print_failed_results) :
        presentation

    if token === nothing && cancellation_source !== nothing
        token = get_token(cancellation_source)
    end

    session = get_session()
    path = string(path)

    # ── Discovery ──
    d = _discover(path)

    if isempty(d.definition_errors) || !fail_on_detection_error
        # Report what detection found *before* filtering. Reporting only the
        # post-filter count makes a filter that matches nothing look identical to
        # a package where detection failed outright.
        n_discovered = length(d)
        n_discovered_files = length(unique(i.uri for i in d))
        if pres.mode !== :none
            printstyled("  Discovered $n_discovered test item(s) in $n_discovered_files file(s)\n"; color=:cyan)
        end

        if filter !== nothing
            d = cd(path) do
                select(d; predicate = i -> filter((filename=i.filename, name=i.name, tags=i.tags, package_name=i.package_name)))
            end
            if pres.mode !== :none && length(d) != n_discovered
                printstyled("  Selected $(length(d)) of $n_discovered after filtering$(_filter_description(filter_description))\n"; color=:cyan)
            end
        end

        if isempty(d) && pres.mode !== :none
            if filter !== nothing && n_discovered > 0
                printstyled("  No test item matched the filter"; color=:yellow)
                println(_filter_description(filter_description), ". Use 'test list' to see what is there.")
            else
                printstyled("  No test items found in $path.\n"; color=:yellow)
            end
        end
    end

    n_total = length(d) * length(environments)

    # Surface the keys where they are needed — next to the progress bar the
    # user is about to watch, not buried in `help`.
    if pres.mode === :bar && n_total > 0
        _print_run_keys()
    end

    p = _make_progress_bar(n_total)

    # ── Execution ──
    _run_counter[] += 1
    run_id = string(_run_counter[])
    _note_workers!(run_id, max_workers)

    run = run_async!(session, d;
        profiles = environments,
        max_workers = max_workers,
        timeout = timeout,
        julia_cmd = julia_cmd,
        julia_args = julia_args,
        fail_on_definition_error = fail_on_detection_error,
        token = token,
        id = run_id,
        metadata = Dict{String,Any}("path" => path, "pres" => pres))
    pres.render = _bar_renderer(run, pres, p)
    subscribe!(run, RunRenderer(run, pres))
    # Announce the id now, while it is unambiguous. Callers that reconstruct it
    # afterwards from "the most recent run" get the wrong answer as soon as two
    # runs start close together.
    on_registered === nothing || on_registered(run_id)

    result = try
        fetch(run)
    finally
        _release_workers!(run_id)
        # Safety-net: clear progress bar in case of cancellation/error/zero tests
        try; ProgressMeter.cancel(p, ""; keep=false); catch; end
        if pres.launch_header_printed
            pres.launch_header_printed = false
            println()
        end
    end

    # ── Reporting ──
    # `pres`, not the kwargs: a run detached to the background mid-flight has had
    # these turned off, and must not write over the prompt it just handed back.
    prog = run_progress(run)
    if pres.show_summary
        println()
        parts = String[]
        n_errors = length(result.definition_errors)
        n_errors > 0 && push!(parts, "$n_errors definition error$(ifelse(n_errors == 1, "", "s"))")
        push!(parts, "$(prog.done) tests ran")
        prog.passed > 0 && push!(parts, "\e[32m$(prog.passed) passed\e[0m")
        prog.failed > 0 && push!(parts, "\e[31m$(prog.failed) failed\e[0m")
        prog.errored > 0 && push!(parts, "\e[31m$(prog.errored) errored\e[0m")
        prog.skipped > 0 && push!(parts, "$(prog.skipped) skipped")
        println(join(parts, ", "), ".")
    end

    if pres.show_failures
        for te in result.definition_errors
            println()
            println("Definition error at $(_fp(te.uri)):$(te.line)")
            println("  $(te.message)")
        end

        for ti in result.testitems, prof in ti.profiles
            prof.status in (:failed, :errored) || continue
            println()
            label = prof.status == :failed ? "FAIL" : "ERROR"
            printstyled("  [$label] $(ti.name)"; color=:red, bold=true)
            if prof.duration !== nothing
                print(" ($(prof.duration)ms)")
            end
            println()
            if prof.messages !== nothing
                for m in prof.messages
                    println("    ", replace(m.message, "\n"=>"\n    "))
                end
            end
        end
    end

    return return_results ? result : run_id
end

"""
    _discover(path) -> Discovery

Discover the test items under `path`. The active project serves as fallback env and
fallback test project for files outside any project; out-of-workspace Project/Manifest
files are loaded lazily by JuliaWorkspaces itself.
"""
function _discover(path)
    active = Base.active_project()
    return discover_testitems(string(path); active_project = active === nothing ? nothing : dirname(active))
end

"Kill every test process; the session stays usable and relaunches on the next run."
kill_test_processes() = (s = _g_session[]; s === nothing || terminate_all_processes!(s); nothing)

kill_test_process(id::String) = terminate_process!(get_session(), id)

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
    # The run this handle belongs to. Learned from `run_tests` at registration
    # time; deriving it afterwards from "the most recently started run" attaches
    # the wrong id as soon as two runs start close together.
    run_id::String
    task::Task
    cts::CancellationTokenSource
    result::Union{Nothing,TestrunResult}
    error::Union{Nothing,Exception}
    start_time::Float64
    # Whether completion has already been announced. Without this the banner
    # reprints on every subsequent command for the rest of the session.
    reported::Bool
end

# Background runs by id. The controller keys everything by testrun_id and runs
# each one independently, so several can be in flight at once; the only reason
# this used to be a single slot was DevREPL's own bookkeeping.
const _bg_runs = Dict{String,BackgroundRun}()
# Guards `_bg_runs`: the result harvester writes to it from its own task.
const _bg_runs_lock = ReentrantLock()

"All background runs, newest first."
function background_runs()
    lock(_bg_runs_lock) do
        sort!(collect(values(_bg_runs)); by=b -> b.start_time, rev=true)
    end
end

"Background runs that have not finished yet."
active_background_runs() = filter(b -> !istaskdone(b.task), background_runs())

"The default worker count for a single run."
default_max_workers() = min(Sys.CPU_THREADS, 8)

"Compact elapsed time: `4.2s`, `1m12s`, `2h03m`."
function _format_elapsed(seconds::Real)
    seconds < 0 && return "-"
    if seconds < 60
        return "$(round(seconds; digits=1))s"
    elseif seconds < 3600
        m, s = divrem(round(Int, seconds), 60)
        return "$(m)m$(lpad(s, 2, '0'))s"
    end
    h, rem = divrem(round(Int, seconds), 3600)
    return "$(h)h$(lpad(rem ÷ 60, 2, '0'))m"
end

"""
    short_id(id, n=8)

The leading chunk of a process or run id. `test kill`, `test log` and
`test attach` all resolve by prefix, so a shortened id stays actionable — and a
full UUID per row is mostly noise.
"""
short_id(id::AbstractString, n::Int=8) = length(id) <= n ? String(id) : String(first(id, n))

# Workers currently allocated per in-flight run. `max_workers` is per-run and the
# controller has no global cap, so without this every concurrent run gets the
# full allowance and the machine ends up with a multiple of it.
const _run_workers = Dict{String,Int}()
const _run_workers_lock = ReentrantLock()

allocated_workers() = lock(_run_workers_lock) do
    sum(values(_run_workers); init=0)
end

_note_workers!(run_id, n) = lock(_run_workers_lock) do
    _run_workers[run_id] = n
end

_release_workers!(run_id) = lock(_run_workers_lock) do
    delete!(_run_workers, run_id)
end

"""
    _worker_budget(requested) -> Int

What a new run may claim: whatever is left of the global allowance, but never
zero — a run with no worker cannot make progress.

An in-flight run's allocation cannot be renegotiated, so the first run keeps its
full speed and later ones take what remains. An explicit `--workers=N` is
honoured as given: that is the user overriding the budget, not asking for a share
of it.
"""
function _worker_budget(requested::Union{Nothing,Int})
    requested === nothing || return requested
    return clamp(default_max_workers() - allocated_workers(), 1, default_max_workers())
end

"Look a background run up by exact id or unique id prefix."
function find_background_run(id::AbstractString)
    lock(_bg_runs_lock) do
        haskey(_bg_runs, id) && return _bg_runs[id]
        matches = [b for (k, b) in _bg_runs if startswith(k, id)]
        length(matches) == 1 ? only(matches) : nothing
    end
end
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
    println("  test run [path|name]            Run test items (Esc cancels, b backgrounds)")
    println("  test run --bg                   Run test items in the background (several may run at once)")
    println("  test attach [id]                Watch a background run as if it were in the foreground")
    println("  test pick [query] [path]        Fuzzy-pick test items to run interactively")
    println("  test failed                     Rerun only the failing items of the last run")
    println("  test repeat                     Repeat the last test run")
    printstyled("\n  Inspecting:\n"; bold=true)
    println("  test list [path]                List discovered test items (alias: ls)")
    println("  test results [id]               Show results (last run, or run #id; alias: res)")
    println("  test failures                   Browse failures of the last run (jump to editor)")
    println("  test history [--active]         List all test runs")
    println("  test status                     Show runs in progress (alias: st)")
    println("  test cancel [id]                Cancel a run (id required when several are active)")
    printstyled("\n  Test processes:\n"; bold=true)
    println("  test procs                      Show active test processes (alias: ps)")
    println("  test kill [process-id]          Kill all or a specific test process")
    println("  test log <process-id>           Show output log for a test process")
    printstyled("\n  Run flags:\n"; bold=true)
    println("  --name=<pattern>                Filter by test item name (substring, case-insensitive)")
    println("  --tags=t1,t2                    Filter by tags")
    println("  --workers=N                     Max parallel workers (default: shared across active runs)")
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
    d = _await_bg() do
        _discover(path)
    end

    tag_filter = if haskey(kwargs, :tags)
        Set(Symbol.(split(kwargs[:tags], ',')))
    else
        nothing
    end

    count = 0
    for item in d
        if tag_filter !== nothing && isempty(intersect(Set(item.tags), tag_filter))
            continue
        end
        tags_str = isempty(item.tags) ? "" : " [$(join(item.tags, ", "))]"
        printstyled("  $(item.name)"; bold=true)
        print("  $(item.filename):$(item.line)")
        if !isempty(tags_str)
            printstyled(tags_str; color=:cyan)
        end
        println()
        count += 1
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

function _collect_testitem_candidates(d::TestItemRuns.Discovery)
    return NamedTuple{(:name, :tags, :filepath, :line),Tuple{String,Vector{Symbol},String,Int}}[
        (name=item.name, tags=item.tags, filepath=item.filename, line=item.line) for item in d
    ]
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
        _collect_testitem_candidates(_discover(path))
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
                path = _run_path(r)
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
        filepath = _fp(ti.uri)
        line = 1
        if prof.messages !== nothing && !isempty(prof.messages)
            m1 = prof.messages[1]
            mpath = try
                p = isempty(m1.uri) ? "" : uri2filepath(URI(m1.uri))
                p === nothing || isempty(p) ? nothing : p
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
            push!(failing, (_fp(ti.uri), ti.name))
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
    e.prof.duration !== nothing && print(" ($(e.prof.duration)ms)")
    println()
    println("  at $(e.filepath):$(e.line)")
    if e.prof.messages !== nothing
        for m in e.prof.messages
            println()
            println("    ", replace(m.message, "\n" => "\n    "))
        end
    end
    if e.prof.output !== nothing && !isempty(strip(e.prof.output))
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

"""
    _run_key_action(byte) -> :cancel | :detach | :none

Decode one keypress read while a run is on screen. Split out from the terminal
plumbing so the key map is testable without a pty.
"""
function _run_key_action(b::UInt8)
    b == 0x1b && return :cancel                       # Esc
    (b == UInt8('b') || b == UInt8('B')) && return :detach
    return :none
end

"""
    _watch_run(test_task, cts, pres) -> :completed | :cancelled | :detached

Watch a running test run from the REPL task, reading single keys in raw mode:

  * **Esc** cancels the run.
  * **b** detaches it — the run carries on, silently, in the background.

Returns how the watch ended. Shared by `test run` and `test attach`, so both
behave identically once a run is on screen.

Detaching silences `pres` here rather than in the caller, so the renderer stops
before this function returns and cannot draw over the prompt the REPL is about
to print.
"""
function _watch_run(test_task::Task, cts::CancellationTokenSource, pres::RunPresentation)
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
        # Fall through — key handling won't work but Ctrl+C still will
    end

    outcome = :completed
    try
        while !istaskdone(test_task)
            if raw_set && bytesavailable(stdin) > 0
                action = _run_key_action(read(stdin, UInt8))
                if action === :cancel
                    cancel(cts)
                    outcome = :cancelled
                    printstyled("\nTest run cancelled (Esc).\n"; color=:yellow)
                    break
                elseif action === :detach
                    detach!(pres)
                    outcome = :detached
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
    return outcome
end

"""
    _settle(test_task; timeout=10.0) -> Bool

Wait for a run to finish unwinding, returning whether it did within `timeout`.

This is what keeps the REPL prompt last. Cancellation is cooperative, so after
Esc the run is still inside `execute_testrun` and has yet to erase the progress
bar and print its summary. Returning to the REPL before that lands means the
prompt is drawn first and then scrolled away by the run's own output — which
reads exactly like a missing prompt. The timeout is a backstop so a wedged run
degrades to messy output rather than a hung REPL.
"""
function _settle(test_task::Task; timeout::Float64=10.0)
    t0 = time()
    while !istaskdone(test_task) && time() - t0 < timeout
        sleep(0.02)
    end
    return istaskdone(test_task)
end

"Record the run id and cached result for `test results` / `test failures`."
function _remember_run(raw=nothing)
    if raw isa String
        _last_run_id[] = raw
    else
        last_id = get_last_run_id()
        last_id === nothing && return nothing
        _last_run_id[] = last_id
    end
    result = get_run_result(_last_run_id[])
    result !== nothing && (_last_result[] = result)
    return nothing
end

# Run tests in the foreground with Esc-to-cancel and b-to-background handling.
# run_kwargs may already contain a filter; cancellation, presentation and result
# bookkeeping are added here.
function _run_blocking(path, run_kwargs)
    # Remember the selection so 'test repeat' can replay it (without the
    # run-specific cancellation state).
    _last_selection[] = (path=path, run_kwargs=copy(run_kwargs))

    cts = CancellationTokenSource()
    # Built here, not inside `run_tests`, so this task keeps the handle it needs
    # to silence the run if the user backgrounds it mid-flight.
    pres = RunPresentation(:bar; show_summary=true, show_failures=true)
    run_kwargs[:cancellation_source] = cts
    run_kwargs[:presentation] = pres
    run_kwargs[:return_results] = false
    run_kwargs[:max_workers] = _worker_budget(get(run_kwargs, :max_workers, nothing))

    # Captured up front so `b` can hand this exact run over to the background.
    run_id = Ref{Union{Nothing,String}}(nothing)

    # Run tests off the REPL's thread so the run keeps progressing regardless of
    # what else the session is doing; that task also owns all progress rendering
    # while the REPL task below does nothing but watch for keys.
    test_task = _spawn_bg() do
        try
            run_tests(path; on_registered=id -> (run_id[] = id), run_kwargs...)
        catch e
            e
        end
    end

    try
        outcome = _watch_run(test_task, cts, pres)

        if outcome === :detached
            _detach_to_background(run_id[], test_task, cts)
            return nothing
        end

        # Both :completed and :cancelled wait, so every line the run prints lands
        # before the REPL draws its prompt.
        _settle(test_task)

        raw = try
            fetch(test_task)
        catch e
            e
        end
        _remember_run(raw)
        raw isa Exception && throw(raw)
    catch e
        if e isa InterruptException
            cancel(cts)
            printstyled("\nTest run cancelled.\n"; color=:yellow)
            _settle(test_task)
            _remember_run()
        else
            rethrow()
        end
    end
    nothing
end

function cmd_run_bg(args; juliaup_channel::Union{Nothing,String}=nothing)
    _check_bg_completion()

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
    run_kwargs[:max_workers] = _worker_budget(get(run_kwargs, :max_workers, nothing))

    # The id is learned from the run itself rather than guessed afterwards, so
    # starting several runs in quick succession still labels each handle right.
    id_slot = Channel{String}(1)
    task = _spawn_bg() do
        try
            run_tests(path; on_registered=id -> put!(id_slot, id), run_kwargs...)
        catch e
            e
        end
    end

    run_id = _await_run_id(id_slot, task)
    if run_id === nothing
        printstyled("The run failed to start.\n"; color=:red)
        return nothing
    end

    _register_background_run(BackgroundRun(run_id, task, cts, nothing, nothing, time(), false))
    printstyled("Test run #$run_id started in background.\n"; color=:green)
    println("  'test status' to check on it, 'test attach $run_id' to watch it.")
    nothing
end

"""
    _await_run_id(id_slot, task) -> String | nothing

Block until the run announces its id, or until the task dies trying. The id is
minted before any work starts, so this returns almost immediately in practice.
"""
function _await_run_id(id_slot::Channel{String}, task::Task; timeout::Float64=30.0)
    t0 = time()
    while time() - t0 < timeout
        isready(id_slot) && return take!(id_slot)
        istaskdone(task) && return isready(id_slot) ? take!(id_slot) : nothing
        sleep(0.01)
    end
    return nothing
end

"""
    _register_background_run(bg)

Record `bg` as a background run and spawn the task that harvests its result when
it finishes. Shared by `test run --bg` and by backgrounding a foreground run with
`b`, so both end up in exactly the same state.
"""
function _register_background_run(bg::BackgroundRun)
    _spawn_bg() do
        raw = try
            fetch(bg.task)
        catch e
            e
        end
        if raw isa Exception
            bg.error = raw
        else
            # Resolve through the id this handle owns, not through whichever run
            # happens to have finished most recently.
            result = get_run_result(bg.run_id)
            result !== nothing && (bg.result = result)
        end
    end

    lock(_bg_runs_lock) do
        _bg_runs[bg.run_id] = bg
    end
    _last_run_id[] = bg.run_id
    return bg
end

"""
    _detach_to_background(run_id, test_task, cts)

Hand an in-flight foreground run over to the background. The run is already
silent by the time this is called — `_watch_run` detached its presentation on the
keypress — so this only has to make it discoverable to `test status`,
`test results` and `test attach`.
"""
function _detach_to_background(run_id::Union{Nothing,String}, test_task::Task, cts::CancellationTokenSource)
    if run_id === nothing
        printstyled("\nCannot background a run that has not registered yet.\n"; color=:yellow)
        return nothing
    end
    _register_background_run(BackgroundRun(run_id, test_task, cts, nothing, nothing, time(), false))
    printstyled("\nTest run #$run_id moved to the background.\n"; color=:cyan)
    println("  'test status' to check on it, 'test attach $run_id' to come back to it.")
    return nothing
end

"""
    cmd_attach(args)

Put the terminal back into the state a background run would have been in had it
been started in the foreground: progress on screen, Esc to cancel, `b` to detach
again.

The run is unaffected either way — attaching only swaps its presentation back on.
"""
function cmd_attach(args=String[])
    bg = _resolve_active_run(args, "attach")
    bg === nothing && return nothing
    run_id = bg.run_id

    if istaskdone(bg.task)
        bg.reported = true
        printstyled("Run #$run_id has already finished.\n"; color=:yellow)
        return cmd_results([run_id])
    end

    run = _find_run(run_id)
    pres = run === nothing ? nothing : _presentation(run)
    if run === nothing || pres === nothing || run.status != :running
        # Registered in the history but not yet dispatching, or already torn
        # down between the checks above and here.
        println("Run #$run_id is not reporting progress yet; try 'test status'.")
        return nothing
    end

    # Exactly one run may render at a time: a run's event sink is the only writer
    # to the terminal while it is in flight, and that invariant is per-run.
    for other in active_background_runs()
        other.run_id == run_id && continue
        orun = _find_run(other.run_id)
        opres = orun === nothing ? nothing : _presentation(orun)
        opres === nothing || detach!(opres)
    end

    # A fresh bar, picking up at the count already reached. The old one belonged
    # to a terminal state that is long gone.
    prog = run_progress(run)
    p = _make_progress_bar(prog.total; start=prog.done)
    pres.render = _bar_renderer(run, pres, p)
    pres.show_summary = true
    pres.show_failures = true
    pres.mode = :bar
    _last_run_id[] = run_id

    printstyled("Attached to test run #$run_id"; color=:cyan)
    println(" ($(prog.done)/$(prog.total) done)")
    _print_run_keys()

    outcome = _watch_run(bg.task, bg.cts, pres)
    if outcome === :detached
        printstyled("\nLeft running in the background.\n"; color=:cyan)
        return nothing
    end
    _settle(bg.task)
    _remember_run()
    return nothing
end

"Print the keys accepted while a run is on screen."
function _print_run_keys()
    printstyled("  Esc"; color=:cyan, bold=true)
    printstyled(" cancel"; color=:light_black)
    printstyled("   b"; color=:cyan, bold=true)
    printstyled(" background\n"; color=:light_black)
    return nothing
end

"""
    _run_progress(bg) -> (done, total, parts)

Progress for one background run, resolved through *its own* context. Looking this
up via the global "most recent run" pointer reports another run's numbers as soon
as more than one is in flight.
"""
function _run_progress(bg::BackgroundRun)
    run = _find_run(bg.run_id)
    run === nothing && return (0, 0, String[])
    prog = run_progress(run)
    parts = String[]
    prog.passed > 0 && push!(parts, "\e[32m$(prog.passed) passed\e[0m")
    prog.failed > 0 && push!(parts, "\e[31m$(prog.failed) failed\e[0m")
    prog.errored > 0 && push!(parts, "\e[31m$(prog.errored) errored\e[0m")
    prog.skipped > 0 && push!(parts, "$(prog.skipped) skipped")
    return (prog.done, prog.total, parts)
end

function cmd_status()
    _check_bg_completion()
    active = active_background_runs()
    if isempty(active)
        println("No test runs in progress.")
        println("  'test history' for past runs, 'test run --bg' to start one.")
        return nothing
    end

    printstyled("Active runs:\n\n"; bold=true)
    printstyled("  $(rpad("#", 6))$(rpad("Elapsed", 10))$(rpad("Progress", 12))Detail\n"; bold=true)
    printstyled("  $(repeat("─", 60))\n"; color=:light_black)
    for bg in active
        done, total, parts = _run_progress(bg)
        elapsed = _format_elapsed(time() - bg.start_time)
        progress = total > 0 ? "$done/$total" : "$done"
        # All items reported but the task is still unwinding — saying "in
        # progress" next to a full count reads as a contradiction.
        detail = if total > 0 && done >= total
            isempty(parts) ? "finishing…" : "finishing… — $(join(parts, ", "))"
        else
            isempty(parts) ? "" : join(parts, ", ")
        end
        print("  $(rpad(bg.run_id, 6))$(rpad(elapsed, 10))$(rpad(progress, 12))")
        println(detail)
    end
    println()
    n = length(active)
    if n == 1
        println("1 run active. 'test attach' to watch it, 'test cancel' to stop it.")
    else
        println("$n runs active. 'test attach <id>' to watch one, 'test cancel <id>' to stop one.")
    end
    nothing
end

"""
    _resolve_active_run(args, verb) -> BackgroundRun | nothing

Pick the run a command should act on: the named one, or the only active one when
no id is given. With several in flight an id is required rather than guessed —
picking "the most recent" would silently act on the wrong run.
"""
function _resolve_active_run(args, verb::AbstractString)
    if !isempty(args)
        bg = find_background_run(String(args[1]))
        bg === nothing && println("No background run matching '$(args[1])'.")
        return bg
    end
    active = active_background_runs()
    if isempty(active)
        println("No background test run to $verb.")
        return nothing
    elseif length(active) > 1
        ids = join(("#" * b.run_id for b in active), ", ")
        println("$(length(active)) runs are active ($ids). Say which: 'test $verb <id>'.")
        return nothing
    end
    return only(active)
end

function cmd_cancel(args=String[])
    bg = _resolve_active_run(args, "cancel")
    bg === nothing && return nothing
    if istaskdone(bg.task)
        println("Run #$(bg.run_id) has already finished.")
        return nothing
    end
    cancel(bg.cts)
    printstyled("Cancel requested for run #$(bg.run_id).\n"; color=:yellow)
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
    if run_record !== nothing && run_record.finished_at !== nothing
        dur = round(_seconds_between(run_record.started_at, run_record.finished_at); digits=1)
        duration_str = " ($dur s)"
    elseif is_active
        dur = round(_seconds_between(run_record.started_at, Dates.now()); digits=1)
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
            println("  $(_fp(de.uri)):$(de.line) — $(de.message)")
        end
    end

    # Show failed/errored details
    for ti in testitems
        for prof in ti.profiles
            if prof.status in (:failed, :errored)
                println()
                label = prof.status == :failed ? "FAIL" : "ERROR"
                printstyled("  [$label] $(ti.name)"; color=:red, bold=true)
                if prof.duration !== nothing
                    print(" ($(prof.duration)ms)")
                end
                println()
                if prof.messages !== nothing
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
                if prof.duration !== nothing
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
    printstyled("  $(rpad("ID", 10))$(rpad("Package", 24))$(rpad("Status", 12))Uptime\n"; bold=true)
    printstyled("  $(repeat("─", 56))\n"; color=:light_black)
    for p in sort(procs; by=x -> x.created_at)
        status_color = if p.status == "Running"
            :green
        elseif p.status == "Idle"
            :light_black
        elseif p.status in ("Launching", "Activating", "Revising")
            :yellow
        else
            :default
        end
        print("  $(rpad(short_id(p.id), 10))$(rpad(p.package_name, 24))")
        printstyled("$(rpad(p.status, 12))"; color=status_color)
        println(_format_elapsed(_seconds_between(p.created_at, Dates.now())))
    end
    println()
    println("$(length(procs)) process(es) active. Ids are shortened; prefixes work in 'test kill' and 'test log'.")
    nothing
end
# ── Display helpers ──────────────────────────────────────────────────────

function _filter_testitems(testitems, name_pattern::String)
    pattern_lower = lowercase(name_pattern)
    filter(ti -> contains(lowercase(ti.name), pattern_lower), testitems)
end

function _print_testitem_details(ti)
    printstyled("\n$(ti.name)"; bold=true)
    println("  $(_fp(ti.uri))")

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
        if prof.duration !== nothing
            print(" ($(prof.duration)ms)")
        end
        println()

        if prof.messages !== nothing
            for msg in prof.messages
                isempty(msg.uri) || println("    $(_fp(msg.uri)):$(msg.line)")
                println("    ", replace(msg.message, "\n" => "\n    "))
            end
        end

        if prof.output !== nothing && !isempty(prof.output)
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
        if prof.output !== nothing && !isempty(prof.output)
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
        started = Dates.format(r.started_at, "HH:MM:SS")
        duration = if r.finished_at !== nothing
            elapsed = _seconds_between(r.started_at, r.finished_at)
            "$(round(elapsed; digits=1))s"
        elseif r.status == :running
            elapsed = _seconds_between(r.started_at, Dates.now())
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
        println(_run_path(r))
    end
    println()
    println("$(length(history)) run(s). Use 'test results <id>' to inspect a run.")
    nothing
end
# ── Helpers ───────────────────────────────────────────────────────────

"""
    _check_bg_completion()

Announce any background run that has finished since the last command, once each.
Called at the top of the interactive commands, so completion surfaces without the
user having to poll.
"""
function _check_bg_completion()
    for bg in background_runs()
        (bg.reported || !istaskdone(bg.task)) && continue
        if bg.error !== nothing
            bg.reported = true
            printstyled("Test run #$(bg.run_id) errored: $(bg.error)\n"; color=:red)
        elseif bg.result !== nothing
            bg.reported = true
            elapsed = _format_elapsed(time() - bg.start_time)
            printstyled("Test run #$(bg.run_id) finished in $elapsed."; color=:green)
            println(" 'test results $(bg.run_id)' for details.")
        end
        # Neither set yet: the task is done but the harvester has not stored the
        # result. Stay unreported so the next command announces it.
    end
    return nothing
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
    "failures", "history", "status", "attach", "cancel", "procs", "kill", "log"]
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
    elseif sub == "attach"
        return cmd_attach(rest)
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
        # Pkg shows precompilation output live, so the workload must stay silent.
        # Two separate channels have to be closed:
        #
        #  * Logging — `ModuleFilterLogger` is installed in `__init__`, which
        #    does not run during precompilation, and the `ConsoleLogger` inside
        #    `run_tests` is task-local and created *after* the reactor task, so
        #    it never covers the reactor's own `@info` calls. A null logger
        #    installed here does, because `get_session()` runs underneath it and
        #    the reactor task inherits its logger at creation.
        #  * stdout/stderr — the progress renderer prints directly, and the
        #    default logger holds the original stderr handle rather than looking
        #    the binding up each time.
        #
        # `progress_ui=:log` stays on purpose: redirecting keeps the renderer in
        # the workload, where `:none` would buy silence by not compiling it.
        Logging.with_logger(Logging.NullLogger()) do
            redirect_stdio(; stdout=devnull, stderr=devnull) do
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
                # Close and drop the session: it holds tasks, which cannot be
                # serialized into the precompile image.
                s = _g_session[]
                s === nothing || close(s)
                _g_session[] = nothing
            end
        end
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
    # Precompilation leaves a stale session with a dead reactor; reset it
    _g_session[] = nothing

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
