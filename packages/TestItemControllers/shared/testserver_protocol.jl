module TestItemServerProtocol

import ..JSONRPC
import ..JSONRPC.JSON

using ..JSONRPC: @dict_readable, RequestType, NotificationType, Outbound

@dict_readable struct Position <: JSONRPC.Outbound
    line::Int
    character::Int
end

struct Range
    start::Position
    stop::Position
end
function Range(d::Dict)
    Range(Position(d["start"]), Position(d["end"]))
end
function JSON.lower(a::Range)
    Dict("start" => a.start, "end" => a.stop)
end

@dict_readable struct Location <: JSONRPC.Outbound
    uri::String
    position::Position
end

@dict_readable struct TestMessageStackFrame <: JSONRPC.Outbound
    label::String
    uri::Union{Missing,String}
    location::Union{Missing,Location}
end

@dict_readable struct TestMessage <: JSONRPC.Outbound
    message::String
    expectedOutput::Union{String,Missing}
    actualOutput::Union{String,Missing}
    location::Location
    stackTrace::Union{Missing,Vector{TestMessageStackFrame}}
end

TestMessage(message, location) = TestMessage(message, missing, missing, location, missing)

@dict_readable struct RunTestItem <: JSONRPC.Outbound
    id::String
    uri::String
    name::String
    packageName::String
    packageUri::String
    useDefaultUsings::Bool
    testSetups::Vector{String}
    line::Int
    column::Int
    code::String
    # Source text of the `skip` kwarg, evaluated in the test process immediately before the
    # item would run. Literals arrive as `"true"`/`"false"`. `missing` means no `skip`.
    skip::Union{Missing,String}
    # Deadline for the test process's own watchdog, in milliseconds. The controller keeps
    # its own timeout as the backstop; this only exists so the worker can produce a
    # diagnostic dump before it is killed.
    timeoutMs::Union{Missing,Float64}
end

struct FileCoverage <: JSONRPC.Outbound
    uri::String
    coverage::Vector{Union{Int,Nothing}}
end

function FileCoverage(d::Dict)
    return FileCoverage(
        d["uri"],
        Union{Int,Nothing}[i for i in d["coverage"]]
    )
end

@dict_readable struct TestsetupDetails <: JSONRPC.Outbound
    packageUri::String
    name::String
    kind::String
    uri::String
    line::Int
    column::Int
    code::String
end

@dict_readable struct ConfigureTestRunRequestParams <: JSONRPC.Outbound
    mode::String
    logLevel::String
    coverageRootUris::Union{Missing,Vector{String}}
    testSetups::Union{Missing,Vector{TestsetupDetails}}
    # Run a full `GC.gc()` after each test item.
    gcBetweenTestitems::Union{Missing,Bool}
    # Fraction of system memory (0..1) above which the test process exits cleanly after
    # finishing an item, so the controller can recycle it.
    memoryThreshold::Union{Missing,Float64}
end

@dict_readable struct RunTestItemsRequestParams <: JSONRPC.Outbound
    mode::String
    coverageRootUris::Union{Vector{String},Missing}
    testItems::Vector{RunTestItem}
end

@dict_readable struct StealTestItemsRequestParams <: JSONRPC.Outbound
    testItemIds::Vector{String}
end

@dict_readable struct ActivateEnvParams <: JSONRPC.Outbound
    projectUri::Union{Missing,String}
    packageUri::String
    packageName::String
end

@dict_readable struct ActivateEnvResult <: JSONRPC.Outbound
    status::String
    error::Union{Missing,String}
end

@dict_readable struct StartedParams <: JSONRPC.Outbound
    testItemId::String
end

# Execution statistics for one test item. Every field is optional: `elapsed`, `bytes`,
# `allocs` and `gctime` come from `@timed`, while the compile timings rely on internals
# that are not available on every Julia version the test process supports.
@dict_readable struct PerfStatsParams <: JSONRPC.Outbound
    elapsed::Union{Missing,Float64}         # milliseconds
    bytes::Union{Missing,Int}
    allocs::Union{Missing,Int}
    gctime::Union{Missing,Float64}          # milliseconds
    compile_time::Union{Missing,Float64}    # milliseconds
    recompile_time::Union{Missing,Float64}  # milliseconds
end

@dict_readable struct PassedParams <: JSONRPC.Outbound
    testItemId::String
    duration::Float64
    coverage::Union{Missing,Vector{FileCoverage}}
    perf::Union{Missing,PerfStatsParams}
end

@dict_readable struct ErroredParams <: JSONRPC.Outbound
    testItemId::String
    messages::Vector{TestMessage}
    duration::Union{Float64,Missing}
    perf::Union{Missing,PerfStatsParams}
end

@dict_readable struct FailedParams <: JSONRPC.Outbound
    testItemId::String
    messages::Vector{TestMessage}
    duration::Union{Float64,Missing}
    perf::Union{Missing,PerfStatsParams}
end

@dict_readable struct SkippedStolenParams <: JSONRPC.Outbound
    testItemId::String
end

# A test item the test process declined to run because its `skip` expression evaluated to
# `true`. Unrelated to `SkippedStolenParams`, which reports an item another process claimed.
@dict_readable struct SkippedParams <: JSONRPC.Outbound
    testItemId::String
    reason::Union{Missing,String}
end

# Reports what a `@testmodule`/`@testsnippet` cost and printed the one time it was
# evaluated on this process, so the controller can replay it and cost future scheduling.
@dict_readable struct SetupEvaluatedParams <: JSONRPC.Outbound
    name::String
    packageUri::String
    durationMs::Union{Missing,Float64}
    output::Union{Missing,String}
end

# Messages from the controller to the test process
const testserver_revise_request_type = JSONRPC.RequestType("testserver/revise", Nothing, String)
const testserver_activate_env_request_type = JSONRPC.RequestType("activateEnv", ActivateEnvParams, ActivateEnvResult)
const configure_testrun_request_type = JSONRPC.RequestType("testserver/ConfigureTestRun", ConfigureTestRunRequestParams, Nothing)
const testserver_run_testitems_batch_request_type = JSONRPC.RequestType("testserver/runTestItems", RunTestItemsRequestParams, Nothing)
const testserver_steal_testitems_request_type = JSONRPC.RequestType("testserver/stealTestItems", StealTestItemsRequestParams, Nothing)
const testserver_shutdown_request_type = JSONRPC.RequestType("testserver/shutdown", Nothing, Nothing)

# Messages from the test process to the controller
const started_notification_type = JSONRPC.NotificationType("started", StartedParams)
const passed_notification_type = JSONRPC.NotificationType("passed", PassedParams)
const errored_notification_type = JSONRPC.NotificationType("errored", ErroredParams)
const failed_notification_type = JSONRPC.NotificationType("failed", FailedParams)
const skipped_stolen_notification_type = JSONRPC.NotificationType("skippedStolen", SkippedStolenParams)
const skipped_notification_type = JSONRPC.NotificationType("skipped", SkippedParams)
const setup_evaluated_notification_type = JSONRPC.NotificationType("setupEvaluated", SetupEvaluatedParams)

end
