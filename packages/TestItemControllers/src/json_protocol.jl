module TestItemControllerProtocol

import ..JSONRPC

using ..JSONRPC: @dict_readable, RequestType, NotificationType, Outbound

@dict_readable struct TestEnvironment <: JSONRPC.Outbound
    id::String
    juliaCmd::String
    juliaArgs::Vector{String}
    juliaNumThreads::Union{Missing,String}
    juliaEnv::Dict{String,Union{String,Nothing}}
    mode::String
    packageName::String
    packageUri::String
    projectUri::Union{Missing,String}
    envContentHash::Union{Missing,String}
    checkBounds::Union{Missing,String}
    # Start the test process with `--color=yes`, so that its output carries ANSI escapes.
    # Both `appendOutput` and `testProcessOutput` then carry them; what to do with them is
    # the client's call.
    color::Union{Missing,Bool}
end

@dict_readable struct TestRunItem <: JSONRPC.Outbound
    testitemId::String
    testEnvId::String
    timeout::Union{Missing,Float64}
    logLevel::String
end

@dict_readable struct TestItemDetail <: JSONRPC.Outbound
    id::String
    uri::String
    label::String
    packageName::String
    packageUri::String
    useDefaultUsings::Bool
    testSetups::Vector{String}
    line::Int
    column::Int
    code::String
    codeLine::Int
    codeColumn::Int
    # The `skip` kwarg: `true`/`false` for a literal, or the source text of an expression the
    # *test process* evaluates immediately before the item would run. Absent means `false`.
    optionSkip::Union{Missing,Bool,String}
end

@dict_readable struct TestSetupDetail <: JSONRPC.Outbound
    packageUri::String
    name::String
    kind::String
    uri::String
    line::Int
    column::Int
    code::String
end

@dict_readable struct CreateTestRunParams <: JSONRPC.Outbound
    testRunId::String
    testEnvironments::Vector{TestEnvironment}
    testItems::Vector{TestItemDetail}
    workUnits::Vector{TestRunItem}
    testSetups::Vector{TestSetupDetail}
    maxProcessCount::Int
    coverageRootUris::Union{Missing,Vector{String}}
end

struct FileCoverage <: JSONRPC.Outbound
    uri::String
    coverage::Vector{Union{Int,Nothing}}
end
FileCoverage(; uri, coverage) = FileCoverage(uri, coverage)
FileCoverage(d::Dict) = FileCoverage(d["uri"], Union{Int,Nothing}[i for i in d["coverage"]])

@dict_readable struct CreateTestRunResponse <: JSONRPC.Outbound
    status::String
    coverage::Union{Missing,Vector{FileCoverage}}
end

const create_testrun_request_type = RequestType("createTestRun", CreateTestRunParams, CreateTestRunResponse)

@dict_readable struct TerminateTestProcessParams
    testProcessId::String
end

const terminate_test_process_request_type = RequestType("terminateTestProcess", TerminateTestProcessParams, Nothing)

# Client -> controller. Graceful shutdown: cancels every run, terminates every test process
# (force-killing those that do not exit within the grace period) and then lets `run` return.
const shutdown_notification_type = NotificationType("shutdown", Nothing)

@dict_readable struct TestMessageStackFrame <: JSONRPC.Outbound
    label::String
    uri::Union{Missing,String}
    line::Union{Missing,Int}
    column::Union{Missing,Int}
end

@dict_readable struct TestMessage <: JSONRPC.Outbound
    message::String
    expectedOutput::Union{Missing,String}
    actualOutput::Union{Missing,String}
    uri::Union{Missing,String}
    line::Union{Missing,Int}
    column::Union{Missing,Int}
    stackTrace::Union{Missing,Vector{TestMessageStackFrame}}
end

# Every test item notification carries `testEnvId` alongside `testItemId`, because the item id
# alone does not identify an item. An id is scoped to its package, so the same package checked
# out into two folders — two worktrees, a vendored copy beside a dev checkout — mints the same
# id from both, and a client keying on the id alone collapses them: one item's results are
# reported twice while the other never resolves. The environment id is what separates them,
# which is how `TestRunState.test_items` and `remaining_work` are keyed on this side.
@dict_readable struct TestItemStartedParams <: Outbound
    testRunId::String
    testItemId::String
    testEnvId::String
end


const notficiationTypeTestItemStarted = NotificationType("testItemStarted", TestItemStartedParams)

# Execution statistics for one test item. Every field is optional: the compile timings in
# particular rely on Julia internals that not every version the test process supports has.
@dict_readable struct PerfStatsParams <: Outbound
    elapsed::Union{Missing,Float64}         # milliseconds
    bytes::Union{Missing,Int}
    allocs::Union{Missing,Int}
    gctime::Union{Missing,Float64}          # milliseconds
    compileTime::Union{Missing,Float64}     # milliseconds
    recompileTime::Union{Missing,Float64}   # milliseconds
end

@dict_readable struct TestItemErroredParams <: Outbound
    testRunId::String
    testItemId::String
    testEnvId::String
    messages::Vector{TestMessage}
    duration::Union{Missing,Float64}
    perf::Union{Missing,PerfStatsParams}
end
const notficiationTypeTestItemErrored = NotificationType("testItemErrored", TestItemErroredParams)

@dict_readable struct TestItemFailedParams <: Outbound
    testRunId::String
    testItemId::String
    testEnvId::String
    messages::Vector{TestMessage}
    duration::Union{Missing,Float64}
    perf::Union{Missing,PerfStatsParams}
end
const notficiationTypeTestItemFailed = NotificationType("testItemFailed", TestItemFailedParams)

@dict_readable struct TestItemPassedParams <: Outbound
    testRunId::String
    testItemId::String
    testEnvId::String
    duration::Union{Missing,Float64}
    perf::Union{Missing,PerfStatsParams}
end

const notficiationTypeTestItemPassed = NotificationType("testItemPassed", TestItemPassedParams)

@dict_readable struct TestItemSkippedParams <: Outbound
    testRunId::String
    testItemId::String
    testEnvId::String
    # Source text of the `skip` expression that evaluated to `true`, when there was one.
    reason::Union{Missing,String}
end

const notficiationTypeTestItemSkipped = NotificationType("testItemSkipped", TestItemSkippedParams)

@dict_readable struct AppendOutputParams <: Outbound
    testRunId::String
    testItemId::Union{Missing,String}
    # Always present, including for the process-level output that has no `testItemId`, so that
    # a client routing output to a test item can key it the same way as the result
    # notifications above.
    testEnvId::String
    output::String
end

const notficiationTypeAppendOutput = NotificationType("appendOutput", AppendOutputParams)

@dict_readable struct TestProcessCreatedParams
    id::String
    packageName::String
    packageUri::Union{Missing,String}
    projectUri::Union{Missing,String}
    coverage::Bool
    env::Dict{String,Union{String, Nothing}}
end

const notificationTypeTestProcessCreated = NotificationType("testProcessCreated", TestProcessCreatedParams)

const notificationTypeTestProcessTerminated = NotificationType("testProcessTerminated", @NamedTuple{id::String})

@dict_readable struct TestProcessStatusChangedParams
    id::String
    status::String
end

const notificationTypeTestProcessStatusChanged = NotificationType("testProcessStatusChanged", TestProcessStatusChangedParams)

@dict_readable struct TestProcessOutputParams
    id::String
    output::String
end

const notificationTypeTestProcessOutput = NotificationType("testProcessOutput", TestProcessOutputParams)

const notificationTypeLaunchDebugger = NotificationType("launchDebugger", @NamedTuple{debugPipeName::String, testRunId::String})

end
