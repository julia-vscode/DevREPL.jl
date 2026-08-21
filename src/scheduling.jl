# ═══════════════════════════════════════════════════════════════════════════════
# Scheduling — failures-first ordering and duration/setup-aware distribution
#
# The model in `schedule_testitems` is a pure function of its arguments so it can
# be tested without spawning a single process. Everything below the model is the
# controller-side glue: the in-memory caches it reads, and the assignment entry
# point `handle!(::ProcsAcquiredMsg)` calls.
# ═══════════════════════════════════════════════════════════════════════════════

"""
    ScheduleItem(id; setups, duration, failed)

One test item as the scheduler sees it.

# Fields
- `id::String` — the test item id. Must be stable across runs for the duration
  cache to be meaningful.
- `setups::Vector{String}` — opaque identifiers of the **`@testmodule`** setups this
  item requires. Snippets must **not** appear here: they are re-evaluated into every
  item's scope on every run, so they have no per-process caching benefit and must not
  influence affinity.
- `duration::Union{Nothing,Float64}` — last measured duration in milliseconds, or
  `nothing` when the item has never run.
- `failed::Bool` — whether the item's last known status was a failure (failed,
  errored, timed out, or lost to a crash).
"""
struct ScheduleItem
    id::String
    setups::Vector{String}
    duration::Union{Nothing,Float64}
    failed::Bool
end

ScheduleItem(id::AbstractString; setups=String[], duration=nothing, failed::Bool=false) =
    ScheduleItem(String(id), collect(String, setups), duration, failed)

# Loads are compared in milliseconds, so a nanosecond of slop is well below anything
# meaningful and keeps the tie-breaks deterministic in the face of float noise.
const _SCHEDULE_TOL = 1e-9

"""
    schedule_testitems(items, workers; setup_costs, worker_setups) -> Dict{String,Vector{String}}

Distribute `items` over `workers`, returning the ordered list of test item ids for
each worker.

This is **parallel machine scheduling with job families and family setup times**. The
load on a worker is

    load(w) = Σ_{i ∈ items(w)} duration(i) + Σ_{s ∈ setups(w)} setup_cost(s)

where `setups(w)` is the *union* of the setups required by the items placed on `w` —
each paid once, because a `@testmodule` is evaluated once per process and cached. The
objective is to minimize `max_w load(w)`; that is NP-hard, so this is a greedy.

Two phases, because failures-first and makespan are different objectives:

1. **Previously failed items** are dealt out one per worker in descending duration, so
   every worker starts on something interesting. Feedback latency beats makespan here,
   so the setup duplication this causes is deliberate.
2. **Everything else** is placed longest-first on the worker minimizing the *incremental*
   load `load(w) + duration(i) + Σ_{s ∈ setups(i) \\ setups(w)} setup_cost(s)`, seeded
   with the loads and setup sets phase 1 produced.

A worker that already holds setup `S` sees only `duration(i)` and so wins against a
worker that would have to pay for `S` — but only until the imbalance exceeds
`setup_cost(S)`, at which point duplicating the setup really is cheaper. The model
degrades correctly at both extremes: with no setup costs it is plain LPT, with no
durations it is pure setup clustering.

# Keyword arguments
- `setup_costs` — measured cost in milliseconds per setup identifier. Setups missing
  from it are priced at the mean known item duration: over-estimating over-clusters,
  under-estimating degrades to plain LPT, so the middle is the safe prior.
- `worker_setups` — setups a worker *already* has evaluated. Our workers survive
  across runs, so a setup warm on a pooled worker costs zero to reuse and the greedy
  routes its items back to that worker.
"""
function schedule_testitems(
    items::AbstractVector{ScheduleItem},
    workers::AbstractVector{<:AbstractString};
    setup_costs::AbstractDict=Dict{String,Float64}(),
    worker_setups::AbstractDict=Dict{String,Set{String}}(),
)
    order = String[String(w) for w in workers]
    assignment = Dict{String,Vector{String}}(w => String[] for w in order)
    (isempty(order) || isempty(items)) && return assignment

    known = Float64[i.duration for i in items if i.duration !== nothing]
    # An item with no recorded duration ranks at the mean of the known ones, so a
    # newly added item lands mid-pack rather than first or last.
    default_duration = isempty(known) ? 0.0 : sum(known) / length(known)
    default_setup_cost = default_duration

    dur(i::ScheduleItem) = i.duration === nothing ? default_duration : i.duration
    cost_of(s::String) = Float64(get(setup_costs, s, default_setup_cost))

    load = Dict{String,Float64}(w => 0.0 for w in order)
    warm = Dict{String,Set{String}}(w => Set{String}(String(s) for s in get(worker_setups, w, ())) for w in order)

    function place!(w::String, item::ScheduleItem)
        push!(assignment[w], item.id)
        extra = 0.0
        for s in item.setups
            if !(s in warm[w])
                push!(warm[w], s)
                extra += cost_of(s)
            end
        end
        load[w] += dur(item) + extra
        return nothing
    end

    # Descending duration, id as a deterministic tie-break.
    longest_first(v) = sort(v; by=i -> (-dur(i), i.id))

    # ── Phase 1 — previously failed items, spread ─────────────────────────────
    for (k, item) in enumerate(longest_first(ScheduleItem[i for i in items if i.failed]))
        place!(order[mod1(k, length(order))], item)
    end

    # ── Phase 2 — everything else, minimum incremental load ───────────────────
    for item in longest_first(ScheduleItem[i for i in items if !i.failed])
        best_idx = 0
        best_cost = Inf
        best_load = Inf
        for (idx, w) in enumerate(order)
            extra = 0.0
            for s in item.setups
                s in warm[w] || (extra += cost_of(s))
            end
            c = load[w] + dur(item) + extra
            if best_idx == 0 || c < best_cost - _SCHEDULE_TOL ||
                    (abs(c - best_cost) <= _SCHEDULE_TOL && load[w] < best_load - _SCHEDULE_TOL)
                best_idx, best_cost, best_load = idx, c, load[w]
            end
        end
        place!(order[best_idx], item)
    end

    return assignment
end

"""
    schedule_makespan(assignment, items; setup_costs, worker_setups) -> Float64

The modelled makespan of an `assignment` — `max_w load(w)`. Diagnostic only; the
scheduler does not use it.
"""
function schedule_makespan(
    assignment::AbstractDict{String,Vector{String}},
    items::AbstractVector{ScheduleItem};
    setup_costs::AbstractDict=Dict{String,Float64}(),
    worker_setups::AbstractDict=Dict{String,Set{String}}(),
)
    by_id = Dict{String,ScheduleItem}(i.id => i for i in items)
    known = Float64[i.duration for i in items if i.duration !== nothing]
    default_duration = isempty(known) ? 0.0 : sum(known) / length(known)

    worst = 0.0
    for (w, ids) in assignment
        warm = Set{String}(String(s) for s in get(worker_setups, w, ()))
        total = 0.0
        for id in ids
            item = get(by_id, id, nothing)
            item === nothing && continue
            total += item.duration === nothing ? default_duration : item.duration
            for s in item.setups
                if !(s in warm)
                    push!(warm, s)
                    total += Float64(get(setup_costs, s, default_duration))
                end
            end
        end
        worst = max(worst, total)
    end
    return worst
end

# ═══════════════════════════════════════════════════════════════════════════════
# Controller-side glue
# ═══════════════════════════════════════════════════════════════════════════════

# Statuses that put an item into phase 1 of the next run.
const _FAILURE_STATUSES = (:failed, :errored, :timeout, :crash)

# Upper bound on the in-memory history. The controller never sees discovery, only
# runs, so entries are pruned lazily against the current run's items rather than
# eagerly — pruning on every run would throw away the history of everything a
# filtered run happened to exclude.
const _SCHEDULING_CACHE_MAX = 20_000

# `c.setup_cost` and `ps.loaded_setups` are keyed by (package_uri, name); the pure
# model takes opaque strings, so flatten here.
_setup_key(package_uri::AbstractString, name::AbstractString) = string(package_uri, "::", name)
_setup_key(k::Tuple{String,String}) = _setup_key(k[1], k[2])

"""
Record that a test item has begun executing.

Deliberately pessimistic: the item is marked as a failure up front, so one that
starts and never reports back — a hang, a timeout, a worker crash, a cancelled run —
is treated as failed by the next run's phase 1. A real terminal result arriving a
moment later overwrites this.
"""
function _record_testitem_started!(c, testitem_id::AbstractString)
    c.last_status[String(testitem_id)] = :errored
    return nothing
end

"""
Record a terminal result for a test item, feeding both the failures-first ordering
and the duration cost model.
"""
function _record_testitem_result!(c, testitem_id::AbstractString, status::Symbol, duration)
    id = String(testitem_id)
    c.last_status[id] = status
    if duration !== nothing && duration !== missing
        c.last_duration[id] = Float64(duration)
    end
    return nothing
end

# Keep the caches bounded. Only fires once the history has grown past the bound, at
# which point everything not in the current run is dropped.
function _prune_scheduling_cache!(c, known_ids)
    if length(c.last_status) + length(c.last_duration) > _SCHEDULING_CACHE_MAX
        keep = Set{String}(known_ids)
        filter!(p -> p.first in keep, c.last_status)
        filter!(p -> p.first in keep, c.last_duration)
    end
    if length(c.setup_cost) > _SCHEDULING_CACHE_MAX
        empty!(c.setup_cost)
    end
    return nothing
end

# `TestSetupEvaluatedMsg` is handled once, in `testitemcontroller.jl` alongside the other
# reactor messages: it populates both `ps.loaded_setups` (for output replay) and
# `c.setup_cost` (for the model below).

# True when we know anything at all about any of these items. With no history the
# model has nothing to work with and we fall back to contiguous chunking.
function _has_scheduling_history(c, ids)
    for id in ids
        (haskey(c.last_duration, id) || haskey(c.last_status, id)) && return true
    end
    return false
end

# Today's behaviour: contiguous chunks over `_get_unchunked_items`. Note this gives no
# setup affinity — `tr.test_items` is a `Dict`, so "contiguous" means contiguous in hash
# order, not source order, and neighbours are unrelated. It stays the first-run fallback
# only because with no durations and no measured setup costs there is nothing better to do.
function _assign_contiguous!(tr::TestRunState, pids::Vector{String}, all_env_items::Vector{String})
    remaining = copy(all_env_items)
    n = length(pids)
    for (k, pid) in enumerate(pids)
        procs_remaining = n - k + 1
        chunk_size = max(1, div(length(remaining), procs_remaining, RoundUp))
        chunk = splice!(remaining, 1:min(chunk_size, length(remaining)))
        tr.testitem_ids_by_proc[pid] = chunk
        @info "Assigned $(length(chunk)) test item(s) to process '$(pid)' (contiguous)"
    end
    return nothing
end

"""
Distribute the test items of one environment over that environment's processes.

Called from `handle!(::ProcsAcquiredMsg)`. Processes that already have an assignment
keep it; only the untouched ones take part.
"""
function _assign_items_to_procs!(c::TestItemController, tr::TestRunState, env::ProcessEnv, proc_ids::Vector{String})
    for pid in proc_ids
        tr.stolen_ids_by_proc[pid] = String[]
    end

    unassigned = String[pid for pid in proc_ids if !haskey(tr.testitem_ids_by_proc, pid)]
    isempty(unassigned) && return nothing

    all_env_items = _get_unchunked_items(tr, env, proc_ids)
    test_env_id = _resolve_test_env_id(tr, env)

    # The scheduling caches are keyed by test item id alone; `tr.test_items` is keyed by
    # `(id, test_env_id)`, so project it back down before pruning against it.
    _prune_scheduling_cache!(c, (k[1] for k in keys(tr.test_items)))

    if c.schedule !== :duration || isempty(all_env_items) || !_has_scheduling_history(c, all_env_items)
        _assign_contiguous!(tr, unassigned, all_env_items)
        return nothing
    end

    # Only `@testmodule` setups are cached per process; snippets are re-evaluated into
    # every item's scope, so they carry no affinity and are filtered out here.
    module_setups = Set{Tuple{String,String}}(
        (s.package_uri, s.name) for s in tr.test_setups if s.kind == "module"
    )

    items = ScheduleItem[]
    for id in all_env_items
        d = get(tr.test_items, (id, test_env_id), nothing)
        d === nothing && continue
        setups = String[
            _setup_key(d.package_uri, n) for n in d.test_setups if (d.package_uri, n) in module_setups
        ]
        push!(items, ScheduleItem(
            id,
            setups,
            get(c.last_duration, id, nothing),
            get(c.last_status, id, :unknown) in _FAILURE_STATUSES,
        ))
    end

    setup_costs = Dict{String,Float64}(_setup_key(k) => v for (k, v) in c.setup_cost)

    # Seed each pooled worker with what it already has loaded. This is the part
    # ReTestItems structurally cannot do — its workers die at the end of every run.
    worker_setups = Dict{String,Set{String}}()
    for pid in unassigned
        ps = get(c.test_processes, pid, nothing)
        ps === nothing && continue
        worker_setups[pid] = Set{String}(_setup_key(k) for k in keys(ps.loaded_setups) if k in module_setups)
    end

    assignment = schedule_testitems(items, unassigned; setup_costs=setup_costs, worker_setups=worker_setups)

    for pid in unassigned
        chunk = assignment[pid]
        tr.testitem_ids_by_proc[pid] = chunk
        n_warm = length(get(worker_setups, pid, ()))
        @info "Assigned $(length(chunk)) test item(s) to process '$(pid)' (duration-aware, $(n_warm) warm setup(s))"
    end
    return nothing
end
