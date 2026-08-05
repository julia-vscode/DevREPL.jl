function makechunks(X::AbstractVector, n::Integer)
    if n<1
        error("n is smaller than 1")
    end
    c = length(X) ÷ n
    return [X[1+c*k:(k == n-1 ? end : c*k+c)] for k = 0:n-1]
end

"""
    TestEnvironment

Describes a Julia process configuration for running test items.

# Fields
- `id::String` — unique identifier for this environment.
- `julia_cmd::String` — path to the Julia executable.
- `julia_args::Vector{String}` — extra command-line arguments passed to Julia.
- `julia_num_threads::Union{Nothing,String}` — value for `JULIA_NUM_THREADS` (or `nothing` for the default).
- `julia_env::Dict{String,Union{String,Nothing}}` — additional environment variables. A `nothing` value removes the variable.
- `mode::String` — one of `"Normal"`, `"Coverage"`, or `"Debug"`.
- `package_name::String` — name of the package under test.
- `package_uri::String` — file URI of the package root.
- `project_uri::Union{Nothing,String}` — file URI of a custom project (or `nothing` for the package default).
- `env_content_hash::Union{Nothing,String}` — opaque hash of the environment content, used to decide whether a pooled process can be reused without a restart.
"""
struct TestEnvironment
    id::String
    julia_cmd::String
    julia_args::Vector{String}
    julia_num_threads::Union{Nothing,String}
    julia_env::Dict{String,Union{String,Nothing}}
    mode::String   # "Normal", "Coverage", or "Debug"
    package_name::String
    package_uri::String
    project_uri::Union{Nothing,String}
    env_content_hash::Union{Nothing,String}
end

"""
    TestRunItem

A single work unit pairing a test item with a test environment.

# Fields
- `testitem_id::String` — identifier of the test item to run.
- `test_env_id::String` — identifier of the [`TestEnvironment`](@ref) to run it in.
- `timeout::Union{Nothing,Float64}` — per-item timeout in seconds, or `nothing` for no timeout.
- `log_level::Symbol` — minimum log level for this item (e.g. `:Debug`, `:Info`, `:Warn`).
"""
struct TestRunItem
    testitem_id::String
    test_env_id::String
    timeout::Union{Nothing,Float64}
    log_level::Symbol
end

"""
    TestItemDetail

Full metadata for a single `@testitem` block.

# Fields
- `id::String` — unique identifier.
- `uri::String` — file URI containing the test item.
- `label::String` — human-readable label.
- `package_name::String` — name of the enclosing package.
- `package_uri::String` — file URI of the package root.
- `option_default_imports::Bool` — whether to inject default `using` statements.
- `test_setups::Vector{String}` — names of `@testsetup` blocks this item depends on.
- `line::Int`, `column::Int` — location of the `@testitem` macro call.
- `code::String` — source code of the test item body.
- `code_line::Int`, `code_column::Int` — location of the code body start.
"""
struct TestItemDetail
    id::String
    uri::String
    label::String
    package_name::String
    package_uri::String
    option_default_imports::Bool
    test_setups::Vector{String}
    line::Int
    column::Int
    code::String
    code_line::Int
    code_column::Int
end

"""
    TestSetupDetail

Metadata for a `@testsetup` or `@testmodule` block.

# Fields
- `package_uri::String` — file URI of the package root.
- `name::String` — setup name referenced by test items.
- `kind::String` — the kind of setup (e.g. `"module"` or `"snippet"`).
- `uri::String` — file URI containing the setup code.
- `line::Int`, `column::Int` — source location.
- `code::String` — source code of the setup body.
"""
struct TestSetupDetail
    package_uri::String
    name::String
    kind::String
    uri::String
    line::Int
    column::Int
    code::String
end

"""
    TestMessageStackFrame

A single frame in a test failure/error stack trace.

# Fields
- `label::String` — display name (e.g. function name).
- `uri::Union{Nothing,String}` — file URI, or `nothing` if unknown.
- `line::Union{Nothing,Int}` — line number, or `nothing`.
- `column::Union{Nothing,Int}` — column number, or `nothing`.
"""
struct TestMessageStackFrame
    label::String
    uri::Union{Nothing,String}
    line::Union{Nothing,Int}
    column::Union{Nothing,Int}
end

"""
    TestMessage

A test failure or error message, optionally with expected/actual output and a stack trace.

# Fields
- `message::String` — the error or failure description.
- `expected_output::Union{Nothing,String}` — expected value string for comparison failures.
- `actual_output::Union{Nothing,String}` — actual value string for comparison failures.
- `uri::Union{Nothing,String}` — file URI where the failure occurred.
- `line::Union{Nothing,Int}` — line number of the failure.
- `column::Union{Nothing,Int}` — column number of the failure.
- `stack_trace::Union{Nothing,Vector{TestMessageStackFrame}}` — stack frames, or `nothing`.
"""
struct TestMessage
    message::String
    expected_output::Union{Nothing,String}
    actual_output::Union{Nothing,String}
    uri::Union{Nothing,String}
    line::Union{Nothing,Int}
    column::Union{Nothing,Int}
    stack_trace::Union{Nothing,Vector{TestMessageStackFrame}}
end

"""
    FileCoverage

Line-level code coverage data for a single file.

# Fields
- `uri::String` — file URI.
- `coverage::Vector{Union{Int,Nothing}}` — one entry per source line. An `Int` is the execution count; `nothing` means the line is not instrumentable.
"""
struct FileCoverage
    uri::String
    coverage::Vector{Union{Int,Nothing}}
end
