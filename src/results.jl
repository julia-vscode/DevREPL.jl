"""
    Results

Aggregate result model for a complete test run, plus JSON serialization.

The execution API of this package reports results incrementally via
[`ControllerCallbacks`](@ref); this submodule provides the shared vocabulary for
clients that need to persist or exchange the aggregated outcome of a run (for
example a CI runner writing results to disk and a reporting step reading them
back). Producers should use [`write_json`](@ref) and consumers [`read_json`](@ref)
so both sides agree on one schema.

All URI fields are plain `String`s.
"""
module Results

import ..JSON

export TestrunResult, TestrunResultTestitem, TestrunResultTestitemProfile,
    TestrunResultMessage, TestrunResultStackFrame, TestrunResultDefinitionError,
    TestrunResultPerfStats, TestrunResultFileCoverage,
    write_json, read_json

"""
    TestrunResultStackFrame

A single frame in a test failure/error stack trace.

# Fields
- `label::String` — display name (e.g. function name).
- `uri::String` — file URI, or the empty string if unknown.
- `line::Int`, `column::Int` — source location, `0` if unknown.
"""
struct TestrunResultStackFrame
    label::String
    uri::String
    line::Int
    column::Int
end

"""
    TestrunResultMessage

A test failure or error message.

# Fields
- `message::String` — the error or failure description.
- `expected_output::Union{Nothing,String}` — expected value string for comparison failures.
- `actual_output::Union{Nothing,String}` — actual value string for comparison failures.
- `uri::String` — file URI where the failure occurred.
- `line::Int`, `column::Int` — source location, `0` if unknown.
- `stack_frames::Union{Nothing,Vector{TestrunResultStackFrame}}` — stack frames, or `nothing`.
"""
struct TestrunResultMessage
    message::String
    expected_output::Union{Nothing,String}
    actual_output::Union{Nothing,String}
    uri::String
    line::Int
    column::Int
    stack_frames::Union{Nothing,Vector{TestrunResultStackFrame}}
end

"""
    TestrunResultPerfStats

Execution statistics for one test item. Every field is optional: the compile timings in
particular depend on Julia internals that are not available on every version.

# Fields
- `elapsed::Union{Nothing,Float64}` — wall-clock time in milliseconds.
- `bytes::Union{Nothing,Int}` — bytes allocated.
- `allocs::Union{Nothing,Int}` — number of allocations.
- `gctime::Union{Nothing,Float64}` — time spent in GC, in milliseconds.
- `compile_time::Union{Nothing,Float64}` — time spent compiling, in milliseconds.
- `recompile_time::Union{Nothing,Float64}` — time spent recompiling, in milliseconds.
"""
struct TestrunResultPerfStats
    elapsed::Union{Nothing,Float64}
    bytes::Union{Nothing,Int}
    allocs::Union{Nothing,Int}
    gctime::Union{Nothing,Float64}
    compile_time::Union{Nothing,Float64}
    recompile_time::Union{Nothing,Float64}

    function TestrunResultPerfStats(elapsed=nothing, bytes=nothing, allocs=nothing,
            gctime=nothing, compile_time=nothing, recompile_time=nothing)
        return new(elapsed, bytes, allocs, gctime, compile_time, recompile_time)
    end
end

"""
    TestrunResultFileCoverage

Line-level coverage for one source file, merged across every test item in the run.

# Fields
- `uri::String` — file URI.
- `coverage::Vector{Union{Nothing,Int}}` — one entry per source line. An `Int` is the
  execution count; `nothing` means the line is not instrumentable.
"""
struct TestrunResultFileCoverage
    uri::String
    coverage::Vector{Union{Nothing,Int}}
end

"""
    TestrunResultTestitemProfile

The outcome of one test item under one run profile (environment).

# Fields
- `profile_name::String` — name of the run profile this result belongs to.
- `status::Symbol` — `:passed`, `:failed`, `:errored`, `:skipped`, `:timeout` or `:crash`.
- `duration::Union{Nothing,Float64}` — duration in milliseconds, or `nothing` when the
  result was synthesised (e.g. timeout or crash).
- `messages::Union{Nothing,Vector{TestrunResultMessage}}` — failure/error messages.
- `output::Union{Nothing,String}` — captured output of the test item.
- `perf::Union{Nothing,TestrunResultPerfStats}` — execution statistics, when measured.
"""
struct TestrunResultTestitemProfile
    profile_name::String
    status::Symbol
    duration::Union{Nothing,Float64}
    messages::Union{Nothing,Vector{TestrunResultMessage}}
    output::Union{Nothing,String}
    perf::Union{Nothing,TestrunResultPerfStats}

    function TestrunResultTestitemProfile(profile_name, status, duration, messages, output,
            perf=nothing)
        return new(profile_name, status, duration, messages, output, perf)
    end
end

"""
    TestrunResultTestitem

One test item with its per-profile outcomes. Results of the same item from
several profiles or matrix legs are merged by `(name, uri)`.

# Fields
- `name::String` — the test item's label.
- `uri::String` — file URI the item is defined in.
- `profiles::Vector{TestrunResultTestitemProfile}` — outcome per run profile.
- `id::String` — the discovery id, `<Package>@<uuid8>/<relpath>::<label>`. Scoped to the
  package, so it is identical between a dev checkout and a CI runner — and, for the same
  reason, identical for two checkouts of the same package. `uri` is what separates those.
  Empty when the producer did not record one.
"""
struct TestrunResultTestitem
    name::String
    uri::String
    profiles::Vector{TestrunResultTestitemProfile}
    id::String

    # `id` is trailing and defaulted so existing positional callers keep working, and so a
    # results file written before this field existed still reads. Empty means "not recorded";
    # consumers that need an id fall back to deriving one, as the JUnit writer does.
    function TestrunResultTestitem(name, uri, profiles, id="")
        return new(name, uri, profiles, id)
    end
end

"""
    TestrunResultDefinitionError

An error detected while discovering test items (e.g. a malformed `@testitem`).
"""
struct TestrunResultDefinitionError
    message::String
    uri::String
    line::Int
    column::Int
end

"""
    TestrunResult

The aggregated outcome of a complete test run.

# Fields
- `definition_errors::Vector{TestrunResultDefinitionError}`
- `testitems::Vector{TestrunResultTestitem}`
- `process_outputs::Dict{String,String}` — captured output per test process id.
- `coverage::Union{Nothing,Vector{TestrunResultFileCoverage}}` — merged line coverage for
  the whole run, or `nothing` when the run did not collect coverage.
"""
struct TestrunResult
    definition_errors::Vector{TestrunResultDefinitionError}
    testitems::Vector{TestrunResultTestitem}
    process_outputs::Dict{String,String}
    coverage::Union{Nothing,Vector{TestrunResultFileCoverage}}

    function TestrunResult(definition_errors, testitems, process_outputs, coverage=nothing)
        return new(definition_errors, testitems, process_outputs, coverage)
    end
end

"""
    write_json(io_or_path, result::TestrunResult)

Serialize `result` as JSON to a stream or file path. The inverse of [`read_json`](@ref).
"""
write_json(io::IO, result::TestrunResult) = JSON.print(io, result)
function write_json(path::AbstractString, result::TestrunResult)
    open(path, "w") do io
        write_json(io, result)
    end
end

"""
    read_json(io_or_path)::TestrunResult

Deserialize a [`TestrunResult`](@ref) previously written with [`write_json`](@ref).
"""
read_json(io::IO) = _testrun_result(JSON.parse(read(io, String)))
read_json(path::AbstractString) = _testrun_result(JSON.parsefile(path))

_opt(f, value) = value === nothing ? nothing : f(value)

# Fields added after the format was first shipped are read through this rather than
# `d[key]`, so results written by an older version still parse. Result files outlive the
# writer — `julia-report-ci-results` merges files produced by every leg of a CI matrix, and
# those legs are not necessarily all on the same version of this package.
_get(d, key) = get(d, key, nothing)

_stack_frame(d) = TestrunResultStackFrame(d["label"], d["uri"], d["line"], d["column"])

_message(d) = TestrunResultMessage(
    d["message"],
    d["expected_output"],
    d["actual_output"],
    d["uri"],
    d["line"],
    d["column"],
    _opt(frames -> TestrunResultStackFrame[_stack_frame(f) for f in frames], d["stack_frames"]),
)

_perf_stats(d) = TestrunResultPerfStats(
    _opt(Float64, _get(d, "elapsed")),
    _opt(Int, _get(d, "bytes")),
    _opt(Int, _get(d, "allocs")),
    _opt(Float64, _get(d, "gctime")),
    _opt(Float64, _get(d, "compile_time")),
    _opt(Float64, _get(d, "recompile_time")),
)

_profile(d) = TestrunResultTestitemProfile(
    d["profile_name"],
    Symbol(d["status"]),
    _opt(Float64, d["duration"]),
    _opt(msgs -> TestrunResultMessage[_message(m) for m in msgs], d["messages"]),
    d["output"],
    _opt(_perf_stats, _get(d, "perf")),
)

_testitem(d) = TestrunResultTestitem(
    d["name"],
    d["uri"],
    TestrunResultTestitemProfile[_profile(p) for p in d["profiles"]],
    something(_get(d, "id"), ""),
)

_definition_error(d) = TestrunResultDefinitionError(d["message"], d["uri"], d["line"], d["column"])

_file_coverage(d) = TestrunResultFileCoverage(
    d["uri"],
    Union{Nothing,Int}[c === nothing ? nothing : Int(c) for c in d["coverage"]],
)

_testrun_result(d) = TestrunResult(
    TestrunResultDefinitionError[_definition_error(e) for e in d["definition_errors"]],
    TestrunResultTestitem[_testitem(t) for t in d["testitems"]],
    Dict{String,String}(k => v for (k, v) in d["process_outputs"]),
    _opt(fcs -> TestrunResultFileCoverage[_file_coverage(f) for f in fcs], _get(d, "coverage")),
)

end
