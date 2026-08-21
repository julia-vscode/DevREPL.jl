module TestItemServer

include("pkg_imports.jl")

import .JSONRPC: @dict_readable
import .CoverageTools: LCOV, amend_coverage_from_src!
import .CancellationTokens: CancellationToken
import Test, Pkg, Sockets
import Logging
import Profile

include("../../../shared/testserver_protocol.jl")

"""
A crash-reporting handler that returns instead of ending the process, or `nothing` when
this process is running outside VS Code.

Distinct from the `error_handler` `serve` takes: that one is for failures the process cannot
continue past and it exits when it is done reporting. This one is for failures worth knowing
about that the caller can carry on from. It is a global because the frames that need it are
reached from deep inside test execution, where there is nothing to thread a handler through.
"""
const NONFATAL_ERROR_HANDLER = Ref{Any}(nothing)

"""
    report_error(err, bt)

Report an exception the caller is going to carry on past. A no-op outside VS Code.
"""
function report_error(err, bt)
    handler = NONFATAL_ERROR_HANDLER[]
    handler === nothing && return nothing
    try
        Base.invokelatest(handler, err, bt)
    catch
        # Reporting a crash must never be the thing that causes one.
    end
    return nothing
end

include("helper.jl")
include("scratch_env.jl")
include("watchdog.jl")

# Exit code the test process uses when it stops itself between test items because system
# memory crossed `memoryThreshold`. The controller recognises it and redistributes the
# process's un-started items instead of reporting a crash — see `_handle_termination_during_run!`.
const MEMORY_RECYCLE_EXIT_CODE = 66

mutable struct Testsetup
    name::String
    kind::Symbol
    uri::String
    line::Int
    column::Int
    code::String
    evaled::Bool
    # Output and wall time captured the one time this setup was evaluated on this process.
    # The output is replayed onto every item that declares the setup — including items from
    # later test runs handed to this pooled process — so which item happened to trigger the
    # evaluation stops being observable. Both are reset when the setup's code changes.
    captured_output::String
    duration::Union{Nothing,Float64}
end

mutable struct TestProcessState
    endpoint::JSONRPC.JSONRPCEndpoint

    test_setups::Dict{Tuple{String,Symbol},Testsetup}
    mode::String
    coverage_root_uris::Union{Nothing,Vector{String}}
    log_level::Base.CoreLogging.LogLevel

    # Run a full `GC.gc()` after every test item. Defaulted by the controller, which turns
    # it on whenever a run has more than one test process.
    gc_between_testitems::Bool
    # Fraction of system memory (0..1) above which we stop after the current item so the
    # controller can recycle us. `nothing` disables the check.
    memory_threshold::Union{Nothing,Float64}

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
            false,
            nothing,
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

"""
    resolve_source_file(file) -> Union{Nothing,String}

The absolute path `file` names, or `nothing` when there is no such file on this machine.

A location is only worth reporting if the editor can open what it points at. Two things
produce paths that do not exist: a relative path recorded for a Base file, which
`Base.find_source_file` resolves, and an absolute path baked in when Julia was built, which
nothing can resolve. The second is what a macro expanding to `@test` — `@test_warn` and the
rest of the `Test` stdlib — reports as the source of a failure, and clicking such a failure
in VS Code answers "The editor could not be opened because the file was not found"
(julia-testitems/TestItemRunner.jl#25, JuliaLang/julia#47033).
"""
function resolve_source_file(file)
    path = string(file)
    isempty(path) && return nothing

    if !isabspath(path)
        resolved = Base.find_source_file(path)
        resolved === nothing && return nothing
        path = resolved
    end

    return isfile(path) ? path : nothing
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

        # The unresolved path still decides whether this is an infrastructure frame, so
        # that a stdlib frame is recognized as one whether or not its file is on disk
        resolved = resolve_source_file(file)
        resolved === nothing || (file = resolved)

        uri = resolved === nothing ? missing : filepath2uri(resolved)
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

        resolved = isempty(file) ? nothing : resolve_source_file(file)
        resolved === nothing || (file = resolved)

        uri = resolved === nothing ? missing : filepath2uri(resolved)
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
            # Coverage for the next item will be polluted by this one's counters, which is
            # wrong but not worth failing the run over. Report it so it can be fixed.
            report_error(err, catch_backtrace())
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

        # `roots === nothing` means the run put no restriction on which files to report,
        # which is what a client that sends no `coverageRootUris` gets. Feeding that to
        # `any` throws a `MethodError`, which the caller's `catch` turns into a spurious
        # "errored" result for whatever test item happened to be running, so the
        # restriction has to be skipped explicitly rather than left to short-circuit on an
        # empty result.
        filter!(cov_info) do i
            isabspath(i.filename) || return false
            if roots !== nothing
                uri = filepath2uri(i.filename)
                # A root is a folder URI and `filepath2uri` never leaves a trailing slash,
                # so a bare prefix test also accepts a sibling whose name merely starts
                # with it — a root of `<workspace>/Foo` collecting `<workspace>/Foo2`.
                any(j -> startswith(uri, endswith(j, "/") ? j : j * "/"), roots) || return false
            end
            return isfile(i.filename)
        end

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

# Maximum amount of a setup's captured output that is replayed onto a dependent item. A
# chatty setup would otherwise be multiplied by the number of items that declare it.
const MAX_REPLAYED_SETUP_OUTPUT = 32 * 1024

function truncate_setup_output(s::AbstractString)
    ncodeunits(s) <= MAX_REPLAYED_SETUP_OUTPUT && return String(s)
    i = MAX_REPLAYED_SETUP_OUTPUT
    while i > 0 && !Base.isvalid(s, i)
        i -= 1
    end
    return string(SubString(s, 1, i), "\n… ($(ncodeunits(s) - i) bytes of setup output truncated)\n")
end

# Evaluate `f` with `stdout`/`stderr` captured into `out[]`, truncated. The redirection is
# process-wide, which is only acceptable because it is used around setup evaluation, where
# the runner loop is the only thing producing output. `out[]` is set even when `f` throws.
function with_captured_output(f, out::Base.RefValue{String})
    orig_stdout = stdout
    orig_stderr = stderr

    rd, wr = redirect_stdout()
    redirect_stderr(wr)

    reader = @async read(rd, String)

    try
        return f()
    finally
        redirect_stdout(orig_stdout)
        redirect_stderr(orig_stderr)
        close(wr)
        out[] = try
            truncate_setup_output(fetch(reader))
        catch err
            # Losing the setup's captured output makes a failing setup much harder to
            # diagnose, so this is worth a report even though we can carry on without it.
            report_error(err, catch_backtrace())
            ""
        end
        close(rd)
    end
end

# Setup output is captured and replayed rather than shown live, so that every item declaring
# the setup sees it and not just whichever item happened to trigger the single evaluation
# (analysis A.3). The fence names the setup, which also explains why a sibling item shows the
# same block.
function replay_setup_output(name::AbstractString, kind::Symbol, text::AbstractString)
    isempty(text) && return

    macro_name = kind === :module ? "@testmodule" : "@testsnippet"

    print(stderr, "\n── output from $macro_name $name (evaluated on this worker) ──\n")
    print(stderr, text)
    endswith(text, "\n") || print(stderr, "\n")
    print(stderr, "── end output from $macro_name $name ──\n")
    flush(stderr)

    return nothing
end

# `Base.cumulative_compile_timing` and `Base.cumulative_compile_time_ns` are internals that
# only exist from Julia 1.8 on, while the test process supports every version back to 1.0
# (see `testprocess/environments/`). Everything below degrades to `missing` instead of
# throwing, so a missing compile timing never turns into a spurious errored test item.
const HAS_COMPILE_TIMING = isdefined(Base, :cumulative_compile_timing) && isdefined(Base, :cumulative_compile_time_ns)

function start_compile_timing()
    HAS_COMPILE_TIMING || return nothing
    try
        Base.cumulative_compile_timing(true)
        before = Base.cumulative_compile_time_ns()
        if !(before isa Tuple{Any,Any})
            Base.cumulative_compile_timing(false)
            return nothing
        end
        return before
    catch err
        return nothing
    end
end

function stop_compile_timing(before)
    before === nothing && return (missing, missing)
    try
        after = Base.cumulative_compile_time_ns()
        Base.cumulative_compile_timing(false)
        return ((after[1] - before[1]) / 1e6, (after[2] - before[2]) / 1e6)
    catch err
        try Base.cumulative_compile_timing(false) catch end
        return (missing, missing)
    end
end

function start_gc_timing()
    try
        return Base.gc_num()
    catch err
        return nothing
    end
end

function collect_perf_stats(elapsed_ms, gc_before, compile_before)
    compile_time, recompile_time = stop_compile_timing(compile_before)

    bytes = missing
    allocs = missing
    gctime = missing

    if gc_before !== nothing
        try
            diff = Base.GC_Diff(Base.gc_num(), gc_before)
            bytes = Int(diff.allocd)
            allocs = Int(Base.gc_alloc_count(diff))
            gctime = diff.total_time / 1e6
        catch err
        end
    end

    return TestItemServerProtocol.PerfStatsParams(
        elapsed = Float64(elapsed_ms),
        bytes = bytes,
        allocs = allocs,
        gctime = gctime,
        compile_time = compile_time,
        recompile_time = recompile_time,
    )
end

# JuliaSyntax treats parentheses as trivia, so the source range recorded for
# `skip=(VERSION < v"1.11")` yields `VERSION < v"1.11"` with the parentheses gone. Splicing
# that back bare would let it reassociate — `skip=a ? b : c` is the clearest case — so the
# text is always re-parenthesized. The newlines mean a trailing line comment cannot swallow
# the closing parenthesis.
parenthesized_skip_code(skip::AbstractString) = string("(\n", skip, "\n)")

"""
    release_module_globals!(mod)

Point every global in `mod` at `nothing`, so that whatever the test item bound to one
becomes collectable.

Every test item runs in a module of its own, and Julia cannot unload a module: the module
stays reachable for the life of the test process, and so does everything its globals point
at. A test item that binds a large array therefore keeps that array alive for every later
item on the same process, which is what julia-testitems/TestItemRunner.jl#65 reports. The
module object itself still leaks — nothing can be done about that — but its contents do
not have to.

Left alone: `eval`, `include` and the module's own name, which the `module` expression
created rather than the test item, and submodules, because a `@testmodule` reached through
one is shared with other test items. Bindings that cannot take `nothing` — a `const` on
Julia before 1.12, a typed global, a name brought in by `using` — are skipped as they come
up, because there is nothing else to try for them.
"""
function release_module_globals!(mod::Module)
    for name in names(mod; all=true)
        (name === :eval || name === :include || name === nameof(mod)) && continue
        # Names Julia generated itself, for closures, generators and macro hygiene
        occursin('#', string(name)) && continue
        isdefined(mod, name) || continue

        try
            getfield(mod, name) isa Module && continue
            # `Core.eval` rather than `setglobal!`, which only exists from Julia 1.9 on
            Core.eval(mod, Expr(:(=), name, nothing))
        catch
        end
    end

    return nothing
end

# `testcode_module_parent` exists for the precompile workload: during package-image
# generation `Main` is closed, so the throwaway module holding the test code must be
# created inside the (still open) TestItemServer module instead.
function run_testitem(endpoint, params::TestItemServerProtocol.RunTestItem, mode::String, coverage_root_uris::Union{Nothing,Vector{String}}, state::TestProcessState; testcode_module_parent::Module=Main)
    # The modules created for this test item, emptied once it is done with them. They are
    # collected here rather than cleared where they are created because `_run_testitem`
    # returns from a dozen places.
    testcode_modules = Module[]

    try
        return _run_testitem(endpoint, params, mode, coverage_root_uris, state, testcode_modules; testcode_module_parent=testcode_module_parent)
    finally
        for m in testcode_modules
            # `invokelatest` is load bearing: the test item's globals were created by an
            # `include_string` in a newer world, and from this one `names(m; all=true)`
            # does not list them yet, so a direct call would find nothing to release.
            Base.invokelatest(release_module_globals!, m)
        end
    end
end

function _run_testitem(endpoint, params::TestItemServerProtocol.RunTestItem, mode::String, coverage_root_uris::Union{Nothing,Vector{String}}, state::TestProcessState, testcode_modules::Vector{Module}; testcode_module_parent::Module=Main)
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

    # `skip` is evaluated here — in the test process, before anything else is done for this
    # item — because that is the only place that can answer `VERSION < v"1.11"` or
    # `Sys.iswindows()` for the process the item would actually have run in. Evaluating it
    # ahead of the setups also means a skipped item never pays for them.
    if params.skip !== missing
        skip_result = nothing
        skip_error = nothing

        try
            skip_module = Core.eval(testcode_module_parent, :(module $(gensym()) end))
            push!(testcode_modules, skip_module)
            skip_result = Base.invokelatest(
                include_string,
                skip_module,
                parenthesized_skip_code(params.skip),
                uri2filepath(params.uri)
            )
        catch err
            skip_error = (err, catch_backtrace())
        end

        if skip_error !== nothing
            err, bt = skip_error

            return (
                TestItemServerProtocol.errored_notification_type,
                TestItemServerProtocol.ErroredParams(
                    testItemId = params.id,
                    messages = [
                        TestItemServerProtocol.TestMessage(
                            message = "Error while evaluating the `skip` option: $(format_error_message(err, bt))",
                            location = TestItemServerProtocol.Location(
                                params.uri,
                                TestItemServerProtocol.Position(params.line, 1)
                            ),
                            stackTrace = backtrace_to_stackframes(bt),
                        )
                    ],
                    duration = missing
                )
            )
        elseif skip_result === true
            return (
                TestItemServerProtocol.skipped_notification_type,
                TestItemServerProtocol.SkippedParams(
                    testItemId = params.id,
                    reason = params.skip
                )
            )
        elseif skip_result !== false
            return (
                TestItemServerProtocol.errored_notification_type,
                TestItemServerProtocol.ErroredParams(
                    testItemId = params.id,
                    messages = [
                        TestItemServerProtocol.TestMessage(
                            "The `skip` option must evaluate to a `Bool`, but it evaluated to a value of type `$(typeof(skip_result))`.",
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
    end

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

            captured_output = Ref("")
            t0 = time_ns()
            try
                # A `@testmodule` runs real package code (it is where a suite does its
                # expensive one-time work), so its coverage window matters as much as a
                # snippet's or the test item's own.
                mode == "Coverage" && clear_coverage_data()
                try
                    with_captured_output(captured_output) do
                        withpath(filepath) do
                            Logging.with_logger(Logging.ConsoleLogger(stderr, state.log_level)) do
                                Base.invokelatest(include_string, mod, code, filepath)
                            end
                        end
                    end
                finally
                    mode == "Coverage" && collect_coverage_data!(coverage_results, coverage_root_uris)
                end
                setup_details.duration = (time_ns() - t0) / 1e6 # Convert to milliseconds
                setup_details.captured_output = captured_output[]
                setup_details.evaled = true

                JSONRPC.send(
                    endpoint,
                    TestItemServerProtocol.setup_evaluated_notification_type,
                    TestItemServerProtocol.SetupEvaluatedParams(
                        name = setup_details.name,
                        packageUri = params.packageUri,
                        durationMs = setup_details.duration,
                        output = setup_details.captured_output,
                    )
                )
            catch err
                elapsed_time = (time_ns() - t0) / 1e6 # Convert to milliseconds

                # Whatever the setup printed before it failed is the most useful thing the
                # user can be shown, so it is replayed here rather than discarded. It is
                # deliberately not cached: the setup stays unevaluated and will be retried.
                replay_setup_output(setup_details.name, :module, captured_output[])

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

    mod = Core.eval(testcode_module_parent, :(module $(gensym()) end))
    push!(testcode_modules, mod)

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

                # Replayed for every item that declares the setup, not just the one that
                # triggered the single evaluation — and on a pooled process that evaluated it
                # during an earlier run, where no item would otherwise show it at all.
                replay_setup_output(testsetup_details.name, :module, testsetup_details.captured_output)
            elseif testsetup_details.kind==:snippet
                testsnippet_filepath = uri2filepath(testsetup_details.uri)
                testsnippet_code = string('\n'^(testsetup_details.line-1), ' '^(testsetup_details.column-1), testsetup_details.code)

                withpath(testsnippet_filepath) do
                    if mode == "Debug"
                        debug_session = wait_for_debug_session()
                        # A setup snippet is not the last thing this session debugs — the
                        # test item's own body follows — and `terminated` would tell the
                        # client the debuggee has ended, so it would disconnect before the
                        # body ran and no breakpoint in the item would ever be hit
                        # (julia-testitems/TestItemRunner.jl#107).
                        DebugAdapter.debug_code(debug_session, mod, testsnippet_code, testsnippet_filepath; notify_termination=false)
                    else
                        mode == "Coverage" && clear_coverage_data()
                        # A snippet is re-evaluated into every item's scope, so its output
                        # already reached every dependent item. It is still captured and
                        # replayed, so that it carries the same fence as a `@testmodule`'s
                        # and so the controller learns what it cost.
                        captured_output = Ref("")
                        t0 = time_ns()
                        try
                            with_captured_output(captured_output) do
                                Logging.with_logger(Logging.ConsoleLogger(stderr, state.log_level)) do
                                    Base.invokelatest(include_string, mod, testsnippet_code, testsnippet_filepath)
                                end
                            end
                        finally
                            testsetup_details.duration = (time_ns() - t0) / 1e6 # Convert to milliseconds
                            testsetup_details.captured_output = captured_output[]
                            mode == "Coverage" && collect_coverage_data!(coverage_results, coverage_root_uris)
                            replay_setup_output(testsetup_details.name, :snippet, captured_output[])
                        end

                        JSONRPC.send(
                            endpoint,
                            TestItemServerProtocol.setup_evaluated_notification_type,
                            TestItemServerProtocol.SetupEvaluatedParams(
                                name = testsetup_details.name,
                                packageUri = params.packageUri,
                                durationMs = testsetup_details.duration,
                                output = testsetup_details.captured_output,
                            )
                        )
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

    # Perf counters are armed around the item body only, so the setups evaluated above are
    # not charged to whichever item happened to trigger them.
    perf = missing
    perf_collected = false
    gc_before = start_gc_timing()
    compile_before = start_compile_timing()

    collect_perf! = () -> begin
        perf_collected && return nothing
        perf_collected = true
        perf = collect_perf_stats(elapsed_time, gc_before, compile_before)
        return nothing
    end

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
                collect_perf!()
            end

            return nothing
        catch err
            elapsed_time = (time_ns() - t0) / 1e6 # Convert to milliseconds
            collect_perf!()

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
                    duration = missing,
                    perf = perf
                )
            )
        finally
            # Belt and braces: whatever path we leave by, the compile-timing counter this
            # item enabled has to be disabled again.
            collect_perf!()
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
                coverage = process_coverage_data(coverage_results),
                perf = perf
            )
        )
    catch err
        if err isa Test.TestSetException
            failed_tests = Test.filter_errors(ts)

            return (
                TestItemServerProtocol.failed_notification_type,
                TestItemServerProtocol.FailedParams(
                    testItemId = params.id,
                    messages = [ create_test_message_for_failed(i, params.uri, params.line) for i in failed_tests],
                    duration = elapsed_time,
                    perf = perf
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

"""
    create_test_message_for_failed(i, fallback_uri, fallback_line)

Turn one failed `Test` result into the message the client shows, located at
`fallback_uri:fallback_line` — the test item itself — when the result points at a file that
is not on this machine.

That happens whenever a macro expands to `@test`: `Test` records the source location of the
`@test` inside the macro's own implementation, and for a Julia built by the build bots that
path does not exist here. Reporting the test item instead keeps the failure clickable, at
the cost of a line number that is the item's rather than the failing call's. See
[`resolve_source_file`](@ref).
"""
function create_test_message_for_failed(i, fallback_uri::AbstractString, fallback_line::Integer)
    (expected, actual) = extract_expected_and_actual(i)

    stack_frames = if :backtrace in fieldnames(typeof(i)) && i.backtrace isa AbstractString && !isempty(i.backtrace)
        parse_backtrace_string(i.backtrace)
    else
        missing
    end

    source_file = resolve_source_file(i.source.file)
    location = source_file === nothing ?
        TestItemServerProtocol.Location(fallback_uri, TestItemServerProtocol.Position(fallback_line, 1)) :
        TestItemServerProtocol.Location(filepath2uri(source_file), TestItemServerProtocol.Position(i.source.line, 1))

    return TestItemServerProtocol.TestMessage(
        message = Base.invokelatest(sprint, Base.show, i),
        expectedOutput = expected,
        actualOutput = actual,
        location = location,
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
        # A test process runs tests in an environment the host has already set up, so
        # refreshing the user's General registry here is a side effect nobody asked for. It
        # also races: test processes belonging to different controllers reach `Pkg.develop`
        # and `Pkg.resolve` at the same time, and on Windows one process's open handle makes
        # another's `unlink` of `registries/General.tar.gz` fail with EBUSY, which fails the
        # whole activation. The controller's precompile gate cannot help, because it only
        # serializes the processes of one controller.
        #
        # This suppresses the automatic registry update only. A package that is missing from
        # the depot still gets installed.
        if isdefined(Pkg, :UPDATED_REGISTRY_THIS_SESSION)
            Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
        end

        # We never activate the user's own environment: `TestEnv.activate` runs
        # `Pkg.instantiate` on whatever is active, which writes a `Manifest.toml`
        # into it. Mirror it into a scratch directory instead — see scratch_env.jl.
        source_uri = params.projectUri===missing ? params.packageUri : params.projectUri
        source_path = source_uri=="" ? nothing : uri2filepath(source_uri)

        source_path===nothing && error("Cannot activate an environment: `$source_uri` is not a file path.")

        scratch = scratch_env(source_path, params.packageName)

        Pkg.activate(scratch.dir)

        if scratch.develop_path!==nothing
            Pkg.develop(Pkg.PackageSpec(path=scratch.develop_path))
        end

        # `TestEnv.activate` replaces the active project with a temporary
        # directory of its own and precompiles in it, so preferences have to
        # reach the test environment through the load path — which it leaves
        # alone — rather than through the active project. Appended, so that
        # preferences of the test environment itself take precedence.
        if scratch.preferences_dir!==nothing && !(scratch.preferences_dir in LOAD_PATH)
            push!(LOAD_PATH, scratch.preferences_dir)
        end

        if params.packageName!=""
            TestEnv.activate(params.packageName)
        end

        # The controller serializes this request: one test process is nominated to activate
        # while every other one waits, and they are released when it reports back. The point
        # of that is to build the test environment's precompile caches exactly once, because
        # Julia has no cache file locking before 1.10 — two processes precompiling the same
        # package race, and on Windows the loser cannot replace a `.ji` the winner holds
        # open, so it dies with "Cannot write cache file".
        #
        # From Julia 1.9 on, `TestEnv.activate` finishes with `Pkg._auto_precompile` on the
        # sandbox environment, so the caches really are built inside that window. The older
        # variants stop at `Pkg.activate`, and `Pkg.instantiate` did not precompile before
        # Julia 1.6 either — so nothing was compiled until the first `using` inside a test
        # item, which happens in every test process at once, after the gate has let them all
        # go. Precompiling here puts that work back inside the serialized window.
        @static if VERSION < v"1.9"
            try
                # `Pkg.precompile` does not exist before Julia 1.4 — it only became a
                # forwarder to `Pkg.API.precompile` then, and before that the name resolved
                # to `Base.precompile` through the implicit `using Base` and threw a
                # MethodError. `Pkg.API.precompile()` has a zero-argument method in every
                # version this branch runs on.
                Pkg.API.precompile()
            catch err
                # Not worth failing activation over: whatever is wrong will come back with a
                # better message when a test item loads the package.
                @debug "Precompiling the test environment failed" exception = (err, catch_backtrace())
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
    state.gc_between_testitems = coalesce(params.gcBetweenTestitems, false)
    state.memory_threshold = coalesce(params.memoryThreshold, nothing)

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
                false,
                "",
                nothing
            )
        else
            val = state.test_setups[key]

            if val.code != i.code || val.kind != i.kind
                val.evaled = false
                val.code = i.code
                val.kind = Symbol(i.kind)
                # The cached output describes the *previous* code, so it must not be
                # replayed onto items in this run — the setup will be re-evaluated and
                # captured again.
                val.captured_output = ""
                val.duration = nothing
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

# Fraction of system memory currently in use, or `nothing` when the OS numbers are not
# available. Deliberately a whole-system figure rather than this process's RSS: what makes
# recycling worth doing is total pressure on the machine, and several test processes share it.
function _memory_over_threshold(threshold::Union{Nothing,Float64})
    threshold === nothing && return false
    return try
        total = Sys.total_memory()
        total == 0 && return false
        (1 - Sys.free_memory() / total) > threshold
    catch err
        false
    end
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
                arm_watchdog!(current_testitem.id, current_testitem.timeoutMs)
                ret = try
                    run_testitem(state.endpoint, current_testitem, state.mode, state.coverage_root_uris, state)
                finally
                    disarm_watchdog!()
                end
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

                # Both of these run *after* the result has been reported, so an item is
                # never charged for the collection and a recycle can never lose a result.
                if state.gc_between_testitems
                    GC.gc(true)
                end

                if _memory_over_threshold(state.memory_threshold)
                    @info "Stopping this test process: system memory use is above the configured threshold of $(state.memory_threshold). The controller will redistribute the remaining test items."
                    flush(stderr)
                    flush(stdout)
                    # Must precede `exit`: it tears the runtime down from this thread, and
                    # racing the watchdog while it is still in Julia code crashed the process
                    # (an `EXCEPTION_ACCESS_VIOLATION` in the JIT on Windows) or left it
                    # failing to exit at all, which stalled the controller's shutdown.
                    stop_watchdog!()
                    exit(MEMORY_RECYCLE_EXIT_CODE)
                end
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

function serve(pipename, debug_pipename, error_handler=nothing, nonfatal_error_handler=nothing)
    NONFATAL_ERROR_HANDLER[] = nonfatal_error_handler

    # Started before anything else, so that a hang anywhere in the run — including one in
    # the very first `activate_env_request` — still leaves diagnostics behind.
    start_watchdog!()

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
        msg = try
            JSONRPC.get_next_message(endpoint)
        catch err
            if err isa JSONRPC.TransportError || err isa JSONRPC.JSONRPCError
                # The controller went away (its client exited, or it crashed). Nobody will
                # ever send `testserver/shutdown` now, so leave instead of lingering as an
                # orphan; nothing here is worth reporting as a crash.
                @info "Connection to the test item controller was lost; exiting."
                stop_watchdog!()
                exit(0)
            end
            rethrow()
        end

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
