"""
    TestProcessState

Mutable state for a single test process managed by the reactor.
"""
mutable struct TestProcessState
    id::String
    fsm::FSM{TestProcessPhase}
    env::ProcessEnv
    testrun_id::Union{Nothing,String}
    jl_process::Union{Nothing,Base.Process}
    endpoint::Union{Nothing,JSONRPC.JSONRPCEndpoint}
    debug_pipe_name::String
    current_testitem_id::Union{Nothing,String}
    current_testitem_started_at::Union{Nothing,Float64}
    has_started_items::Bool
    timeout_cs::Union{Nothing,CancellationTokens.CancellationTokenSource}
    timeout_reg::Any  # Union{Nothing,CancellationTokens.CancellationTokenRegistration}
    # Process lifecycle
    cs::CancellationTokens.CancellationTokenSource        # process-level cancellation
    termination_reg::Any   # Union{Nothing,CancellationTokens.CancellationTokenRegistration}
    process_tasks::Vector{Task}
    # When true, the merged TestProcessTerminatedMsg posted after this process
    # dies will carry skip_remaining=true so the controller treats any
    # un-started items on the process as user-skipped rather than redistributing.
    skip_remaining_on_termination::Bool
    is_precompile_process::Bool
    precompile_done::Bool
    test_env_content_hash::Union{Nothing,String}
    # Per-testrun context (set when assigned to a testrun, cleared on return to pool)
    testrun_token::Union{Nothing,CancellationTokens.CancellationToken}
    testrun_watcher_registration::Any
    test_setups::Any     # Union{Nothing, Vector{TestsetupDetails}}
    coverage_root_uris::Any
    proc_log_level::Symbol
    # Exit info captured when the OS process dies (set in _launch_julia_process! catch)
    last_exit_code::Union{Nothing,Int}
    last_term_signal::Union{Nothing,Int}
end

function TestProcessState(id::String, env::ProcessEnv;
        is_precompile_process::Bool=false,
        precompile_done::Bool=false,
        test_env_content_hash=nothing)
    return TestProcessState(
        id,
        testprocess_fsm(id),
        env,
        nothing,                                        # testrun_id
        nothing,                                        # jl_process
        nothing,                                        # endpoint
        JSONRPC.generate_pipe_name(),                   # debug_pipe_name
        nothing,                                        # current_testitem_id
        nothing,                                        # current_testitem_started_at
        false,                                          # has_started_items
        nothing,                                        # timeout_cs
        nothing,                                        # timeout_reg
        CancellationTokens.CancellationTokenSource(),   # cs
        nothing,                                        # termination_reg
        Task[],                                         # process_tasks
        false,                                          # skip_remaining_on_termination
        is_precompile_process,
        precompile_done,
        test_env_content_hash,
        nothing,                                        # testrun_token
        nothing,                                        # testrun_watcher_registration
        nothing,                                        # test_setups
        nothing,                                        # coverage_root_uris
        :Info,                                          # proc_log_level
        nothing,                                        # last_exit_code
        nothing,                                        # last_term_signal
    )
end

"""
    TestRunState

Mutable state for a single test run managed by the reactor.
"""
mutable struct TestRunState
    id::String
    fsm::FSM{TestRunPhase}
    test_environments::Vector{TestEnvironment}
    env_by_id::Dict{String,TestEnvironment}
    remaining_work::Dict{Tuple{String,String},TestRunItem}  # (testitem_id, test_env_id) → work unit
    test_items::Dict{String,TestItemDetail}                 # lookup by testitem_id
    test_setups::Vector{TestSetupDetail}
    max_processes::Int
    coverage_root_uris::Union{Nothing,Vector{String}}
    procs::Union{Nothing,Dict{ProcessEnv,Vector{String}}}   # process IDs by env
    testitem_ids_by_proc::Dict{String,Vector{String}}
    stolen_ids_by_proc::Dict{String,Vector{String}}
    items_dispatched_to_procs::Set{String}
    processes_ready_before_acquired::Set{String}
    coverage::Vector{CoverageTools.FileCoverage}
    cancellation_source::CancellationTokens.CancellationTokenSource
    completion_channel::Channel{Any}    # reactor puts result here; execute_testrun waits on it
end

function TestRunState(
    id::String,
    test_environments::Vector{TestEnvironment},
    items::Vector{TestItemDetail},
    work_units::Vector{TestRunItem},
    test_setups::Vector{TestSetupDetail},
    max_processes::Int;
    coverage_root_uris::Union{Nothing,Vector{String}}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
)
    cancellation_source = token === nothing ?
        CancellationTokens.CancellationTokenSource() :
        CancellationTokens.CancellationTokenSource(token)

    env_by_id = Dict(e.id => e for e in test_environments)

    return TestRunState(
        id,
        testrun_fsm(id),
        test_environments,
        env_by_id,
        Dict{Tuple{String,String},TestRunItem}((wu.testitem_id, wu.test_env_id) => wu for wu in work_units),
        Dict{String,TestItemDetail}(item.id => item for item in items),
        test_setups,
        max_processes,
        coverage_root_uris,
        nothing,                                    # procs
        Dict{String,Vector{String}}(),              # testitem_ids_by_proc
        Dict{String,Vector{String}}(),              # stolen_ids_by_proc
        Set{String}(),                              # items_dispatched_to_procs
        Set{String}(),                              # processes_ready_before_acquired
        CoverageTools.FileCoverage[],               # coverage
        cancellation_source,
        Channel{Any}(1),                            # completion_channel
    )
end

"""
Resolve which TestEnvironment a ProcessEnv belongs to.
"""
function _resolve_test_env_id(tr::TestRunState, penv::ProcessEnv)::String
    for env in tr.test_environments
        if ProcessEnv(env) == penv
            return env.id
        end
    end
    error("No matching TestEnvironment for ProcessEnv")
end
