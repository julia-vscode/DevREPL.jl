"""Messages processed by the reactor event loop."""
abstract type ReactorMessage end

# ═══════════════════════════════════════════════════════════════════════════════
# Controller-level messages (handled by the reactor)
# ═══════════════════════════════════════════════════════════════════════════════

struct ShutdownMsg <: ReactorMessage end

# Posted by a timer armed in `handle!(::ShutdownMsg)`. If processes are still tracked when
# it arrives, they are force-killed and dropped so the reactor loop is guaranteed to exit.
struct ShutdownDeadlineMsg <: ReactorMessage end

struct GetProcsForTestRunMsg <: ReactorMessage
    testrun_id::String
    proc_count_by_env::Dict{ProcessEnv,Int}
    env_content_hash_by_env::Dict{ProcessEnv,Union{Nothing,String}}
    test_setups::Vector{TestItemServerProtocol.TestsetupDetails}
    coverage_root_uris::Union{Nothing,Vector{String}}
    log_level::Symbol
end

struct ReturnToPoolMsg <: ReactorMessage
    testprocess_id::String
    env::ProcessEnv
end

# Posted from the per-process IO task in `start()` after the process has fully
# exited. Carries enough context to drive both run-level redistribution
# (testrun_id, skip_remaining) and controller-level pool cleanup in one handler,
# so callers never need to coordinate two messages.
struct TestProcessTerminatedMsg <: ReactorMessage
    testprocess_id::String
    testrun_id::Union{Nothing,String}   # nothing if the process died outside any test run
    skip_remaining::Bool                # only meaningful when testrun_id !== nothing
end
TestProcessTerminatedMsg(id::String) = TestProcessTerminatedMsg(id, nothing, false)

struct TestProcessStatusChangedMsg <: ReactorMessage
    testprocess_id::String
    status::String
end

struct TestProcessOutputMsg <: ReactorMessage
    testprocess_id::String
    output::String
end

# ═══════════════════════════════════════════════════════════════════════════════
# Test-run messages (handled by the reactor)
# ═══════════════════════════════════════════════════════════════════════════════

struct ProcsAcquiredMsg <: ReactorMessage
    testrun_id::String
    procs::Dict{ProcessEnv,Vector{String}}  # env → process IDs
end

struct TestRunCancelledMsg <: ReactorMessage
    testrun_id::String
end

struct ReadyToRunTestItemsMsg <: ReactorMessage
    testrun_id::String
    testprocess_id::String
end

struct PrecompileDoneMsg <: ReactorMessage
    testrun_id::String
    env::ProcessEnv
    testprocess_id::String
end

struct AttachDebuggerMsg <: ReactorMessage
    testrun_id::String
    debug_pipe_name::String
end

struct TestItemStartedMsg <: ReactorMessage
    testrun_id::String
    testprocess_id::String
    testitem_id::String
end

struct TestItemPassedMsg <: ReactorMessage
    testrun_id::String
    testprocess_id::String
    testitem_id::String
    duration::Float64
    coverage::Union{Nothing,Vector{Any}}
    perf::Union{Nothing,PerfStats}
end
TestItemPassedMsg(testrun_id, testprocess_id, testitem_id, duration, coverage) =
    TestItemPassedMsg(testrun_id, testprocess_id, testitem_id, duration, coverage, nothing)

struct TestItemFailedMsg <: ReactorMessage
    testrun_id::String
    testprocess_id::String
    testitem_id::String
    messages::Vector{Any}
    duration::Union{Nothing,Float64}
    perf::Union{Nothing,PerfStats}
end
TestItemFailedMsg(testrun_id, testprocess_id, testitem_id, messages, duration) =
    TestItemFailedMsg(testrun_id, testprocess_id, testitem_id, messages, duration, nothing)

struct TestItemErroredMsg <: ReactorMessage
    testrun_id::String
    testprocess_id::String
    testitem_id::String
    messages::Vector{Any}
    duration::Union{Nothing,Float64}
    perf::Union{Nothing,PerfStats}
end
TestItemErroredMsg(testrun_id, testprocess_id, testitem_id, messages, duration) =
    TestItemErroredMsg(testrun_id, testprocess_id, testitem_id, messages, duration, nothing)

struct TestItemSkippedStolenMsg <: ReactorMessage
    testrun_id::String
    testprocess_id::String
    testitem_id::String
end

# The test process declined to run an item because its `skip` expression was true. Nothing
# to do with `TestItemSkippedStolenMsg`, which reports an item another process claimed.
struct TestItemSkippedMsg <: ReactorMessage
    testrun_id::String
    testprocess_id::String
    testitem_id::String
    reason::Union{Nothing,String}
end

# A `@testmodule`/`@testsnippet` was evaluated on a test process. Process-level rather than
# run-level: the result stays valid for as long as the process caches the setup, including
# across runs.
struct TestSetupEvaluatedMsg <: ReactorMessage
    testprocess_id::String
    package_uri::String
    name::String
    duration::Union{Nothing,Float64}
    output::String
end

struct AppendOutputMsg <: ReactorMessage
    testrun_id::String
    testprocess_id::String
    testitem_id::Union{Nothing,String}
    output::String
end

struct TestItemTimeoutMsg <: ReactorMessage
    testrun_id::String
    testprocess_id::String
    testitem_id::String
end

# ═══════════════════════════════════════════════════════════════════════════════
# Process-lifecycle messages (from IO tasks → reactor)
# ═══════════════════════════════════════════════════════════════════════════════

struct TestProcessLaunchedMsg <: ReactorMessage
    testprocess_id::String
    jl_process::Base.Process
    endpoint::JSONRPC.JSONRPCEndpoint
end

struct TestProcessActivatedMsg <: ReactorMessage
    testprocess_id::String
end

struct TestProcessTestSetupsLoadedMsg <: ReactorMessage
    testprocess_id::String
end

struct TestProcessReviseResultMsg <: ReactorMessage
    testprocess_id::String
    needs_restart::Bool
end

struct TestProcessIOErrorMsg <: ReactorMessage
    testprocess_id::String
    error_type::Symbol  # :restart or :fatal
    exit_code::Union{Nothing,Int}
    term_signal::Union{Nothing,Int}
end
TestProcessIOErrorMsg(id::String, error_type::Symbol) = TestProcessIOErrorMsg(id, error_type, nothing, nothing)

struct ActivationFailedMsg <: ReactorMessage
    testprocess_id::String
    error_message::String
end

struct TerminateTestProcessMsg <: ReactorMessage
    testprocess_id::String
end


