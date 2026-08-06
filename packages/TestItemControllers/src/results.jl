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
    TestrunResultTestitemProfile

The outcome of one test item under one run profile (environment).

# Fields
- `profile_name::String` — name of the run profile this result belongs to.
- `status::Symbol` — `:passed`, `:failed`, `:errored`, `:skipped`, `:timeout` or `:crash`.
- `duration::Union{Nothing,Float64}` — duration in milliseconds, or `nothing` when the
  result was synthesised (e.g. timeout or crash).
- `messages::Union{Nothing,Vector{TestrunResultMessage}}` — failure/error messages.
- `output::Union{Nothing,String}` — captured output of the test item.
"""
struct TestrunResultTestitemProfile
    profile_name::String
    status::Symbol
    duration::Union{Nothing,Float64}
    messages::Union{Nothing,Vector{TestrunResultMessage}}
    output::Union{Nothing,String}
end

"""
    TestrunResultTestitem

One test item with its per-profile outcomes. Results of the same item from
several profiles or matrix legs are merged by `(name, uri)`.
"""
struct TestrunResultTestitem
    name::String
    uri::String
    profiles::Vector{TestrunResultTestitemProfile}
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
"""
struct TestrunResult
    definition_errors::Vector{TestrunResultDefinitionError}
    testitems::Vector{TestrunResultTestitem}
    process_outputs::Dict{String,String}
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

_profile(d) = TestrunResultTestitemProfile(
    d["profile_name"],
    Symbol(d["status"]),
    _opt(Float64, d["duration"]),
    _opt(msgs -> TestrunResultMessage[_message(m) for m in msgs], d["messages"]),
    d["output"],
)

_testitem(d) = TestrunResultTestitem(
    d["name"],
    d["uri"],
    TestrunResultTestitemProfile[_profile(p) for p in d["profiles"]],
)

_definition_error(d) = TestrunResultDefinitionError(d["message"], d["uri"], d["line"], d["column"])

_testrun_result(d) = TestrunResult(
    TestrunResultDefinitionError[_definition_error(e) for e in d["definition_errors"]],
    TestrunResultTestitem[_testitem(t) for t in d["testitems"]],
    Dict{String,String}(k => v for (k, v) in d["process_outputs"]),
)

end
