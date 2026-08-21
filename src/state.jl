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
    # Setups this process has already evaluated, keyed by (package_uri, setup_name). The
    # captured output is replayed onto every item that declares the setup (not just the one
    # that happened to trigger evaluation), and the duration feeds the scheduling cost
    # model. Populated from `setup_evaluated` notifications; survives across test runs
    # exactly as long as the process's cached setups do.
    loaded_setups::Dict{Tuple{String,String},@NamedTuple{output::String, duration::Union{Nothing,Float64}}}
    # Exit info captured when the OS process dies (set in _launch_julia_process! catch)
    last_exit_code::Union{Nothing,Int}
    last_term_signal::Union{Nothing,Int}
    # Last time anything was heard from this process, on each of its two independent
    # channels: the JSON-RPC socket that carries every result, and the stdout/stderr pipes
    # that carry captured output. Diagnostics only — nothing branches on these. They exist
    # because the two can diverge: a process whose socket has gone silent while its output
    # still flows is a broken connection, not a hung test, and without both timestamps that
    # distinction is invisible in the log.
    last_message_at::Union{Nothing,Float64}
    last_output_at::Union{Nothing,Float64}
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
        Dict{Tuple{String,String},@NamedTuple{output::String, duration::Union{Nothing,Float64}}}(),  # loaded_setups
        nothing,                                        # last_exit_code
        nothing,                                        # last_term_signal
        nothing,                                        # last_message_at
        nothing,                                        # last_output_at
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
    # Keyed by `(testitem_id, test_env_id)`, not by id alone. A test item id is scoped to
    # its package, so the same package checked out into two folders — two worktrees, a
    # vendored copy beside a dev checkout — mints the same id from both. Keyed by id alone
    # they collapsed into one entry, and the surviving entry's source then ran twice while
    # the other item silently never ran at all.
    #
    # The environment id rather than the package uri, because an id is an opaque string
    # minted by the caller while a uri has several valid spellings for one folder — an 8.3
    # short path, a drive letter of either case — and two producers of the "same" uri do not
    # reliably agree. `remaining_work` is keyed the same way.
    test_items::Dict{Tuple{String,String},TestItemDetail}
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
    reported_items::Set{String}         # testitem_ids for which a terminal callback was emitted
    # Worker lifecycle policy for this run, sent on to each process in ConfigureTestRun.
    # `gc_between_testitems` is resolved from the caller's request in `execute_testrun`
    # (default: on whenever the run uses more than one process).
    gc_between_testitems::Bool
    memory_threshold::Union{Nothing,Float64}
end

"""
    _index_items_by_env(items, work_units, test_environments)

Resolve each work unit to the test item detail it should run, keyed by
`(testitem_id, test_env_id)`.

Ids are unique per package, so in the ordinary case one id names one item and every
environment running it wants that same detail — no package matching required, which matters
because comparing package uris is not dependable: the same folder can be spelled with an 8.3
short path or a long one, with either drive-letter case, and two producers of the "same" uri
need not agree.

Only when one id genuinely names several items — the same package checked out twice — is
there anything to disambiguate, and then the package uri is the only thing that can do it. So
the fragile comparison is confined to the case that cannot be resolved without it, and is
never on the path an ordinary run takes.
"""
function _index_items_by_env(items::Vector{TestItemDetail}, work_units::Vector{TestRunItem},
        test_environments::Vector{TestEnvironment})
    by_id = Dict{String,Vector{TestItemDetail}}()
    for item in items
        push!(get!(Vector{TestItemDetail}, by_id, item.id), item)
    end

    package_by_env = Dict(e.id => e.package_uri for e in test_environments)
    result = Dict{Tuple{String,String},TestItemDetail}()

    for wu in work_units
        candidates = get(by_id, wu.testitem_id, nothing)
        candidates === nothing && continue

        item = if length(candidates) == 1
            only(candidates)
        else
            env_package = get(package_by_env, wu.test_env_id, nothing)
            match = env_package === nothing ? nothing :
                findfirst(c -> _same_package(c.package_uri, env_package), candidates)
            match === nothing ? first(candidates) : candidates[match]
        end

        result[(wu.testitem_id, wu.test_env_id)] = item
    end

    return result
end

# Case-insensitive because Windows paths are, and the two spellings of one folder differ in
# case often enough to matter. Not a full canonicalisation — this only has to separate two
# checkouts of one package, which live at visibly different paths.
_same_package(a::AbstractString, b::AbstractString) = lowercase(a) == lowercase(b)

function TestRunState(
    id::String,
    test_environments::Vector{TestEnvironment},
    items::Vector{TestItemDetail},
    work_units::Vector{TestRunItem},
    test_setups::Vector{TestSetupDetail},
    max_processes::Int;
    coverage_root_uris::Union{Nothing,Vector{String}}=nothing,
    token::Union{Nothing,CancellationTokens.CancellationToken}=nothing,
    gc_between_testitems::Bool=false,
    memory_threshold::Union{Nothing,Float64}=nothing,
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
        _index_items_by_env(items, work_units, test_environments),
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
        Set{String}(),                              # reported_items
        gc_between_testitems,
        memory_threshold,
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
