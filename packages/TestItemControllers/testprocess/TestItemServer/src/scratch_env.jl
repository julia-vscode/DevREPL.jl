# Materializing a scratch environment
#
# `TestEnv.activate` calls `Pkg.instantiate` on whatever environment is active
# when it runs (`ctx_and_pkgspec` in the vendored TestEnv). For an environment
# with a `Project.toml` but no `Manifest.toml` that resolves and writes a
# manifest straight into that directory. Running test items must never modify
# the user's working tree, and TestEnv is vendored from upstream so we cannot
# patch it — therefore we never make the user's environment the active one.
# Instead we build a throwaway *wrapper* environment that mirrors it and
# activate that.
#
# The wrapper is deliberately nameless (no `name`/`uuid`/`version`) and carries
# the source project's own package as an ordinary path-tracked dependency. That
# is not a stylistic choice: Pkg derives the root package's source location from
# `dirname(env.project_file)` in two places —
#
#   * `Pkg.Operations.sandbox_preserve`, which injects the root entry with
#     `path = dirname(env.project_file)`, and
#   * TestEnv's `get_test_dir`, which sets `pkgspec.path = dirname(ctx.env.project_file)`
#     when the package *is* the active project.
#
# A verbatim copy of the package's own `Project.toml` would therefore point both
# of them at the scratch directory, which has no `src/` and no `test/`. Leaving
# the wrapper nameless routes both through the `[sources]`/manifest entry
# instead, which we aim back at the real package folder.
#
# Not activating the user's environment has a second consequence, and it is the
# reason for the preferences carrier below. `TestEnv.activate` makes a temporary
# directory of its own the active project and precompiles in it, carrying over
# only the project and the manifest — never preferences. Whatever we put next to
# the scratch project is therefore out of the picture by the time anything is
# compiled, so the user's preferences have to reach the test environment through
# `LOAD_PATH`, which TestEnv leaves alone.
#
# Everything here works at the TOML level rather than through `Pkg.Types.Project`
# / `Pkg.Types.Manifest`. Those types, and the helpers that operate on them
# (`Pkg.Operations.abspath!` in particular), changed shape repeatedly between
# Julia 1.0 and 1.13, and this file has to run on all of them.

const _PROJECT_NAMES = ("JuliaProject.toml", "Project.toml")

const _MANIFEST_NAMES = (
    "JuliaManifest-v$(VERSION.major).$(VERSION.minor).toml",
    "Manifest-v$(VERSION.major).$(VERSION.minor).toml",
    "JuliaManifest.toml",
    "Manifest.toml",
)

const _LOCAL_PREFERENCES_NAMES = ("JuliaLocalPreferences.toml", "LocalPreferences.toml")

# `[sources]` is how a project pins a dependency to a folder without a manifest.
# Before Julia 1.11 there is no such section, so a manifest-less environment can
# only be pinned by actually running `Pkg.develop` in it.
const _SUPPORTS_SOURCES = VERSION >= v"1.11.0"

# Project keys that only make sense for a *named* package, or that would make
# Pkg look for something inside the scratch directory.
#
# `extras`/`targets` go because TestEnv reads the test target from the real
# package's `Project.toml` (via `gen_target_project`), not from the active
# environment. `weakdeps`/`extensions` describe extensions of the source
# package, which the wrapper is not. `workspace` members and `manifest`/
# `entryfile`/`path` are all resolved relative to the project file, so keeping
# them would send Pkg into the scratch directory.
const _STRIPPED_PROJECT_KEYS = (
    "name", "uuid", "version",
    "extras", "targets",
    "weakdeps", "extensions",
    "workspace", "apps",
    "manifest", "entryfile", "path",
)

"""
    ScratchEnv

The result of [`materialize_scratch_env`](@ref).

* `dir` — the scratch environment's directory, ready to be passed to `Pkg.activate`.
* `develop_path` — a package folder the caller must `Pkg.develop` *after*
  activating `dir`, or `nothing`. Only ever set on Julia versions without
  `[sources]` support and only when the source environment has no manifest, in
  which case there is no declarative way to pin the package to its folder.
* `preferences_dir` — an environment directory carrying nothing but the source
  environment's preferences, which the caller must append to `LOAD_PATH`, or
  `nothing` when the source environment sets no preferences.
"""
struct ScratchEnv
    dir::String
    develop_path::Union{Nothing,String}
    preferences_dir::Union{Nothing,String}
end

const _SCRATCH_ENVS = Dict{Tuple{String,String},ScratchEnv}()

"""
    scratch_env(project_path, package_name) -> ScratchEnv

[`materialize_scratch_env`](@ref), memoized for the lifetime of the process so
that repeated activations of the same environment do not pile up temporary
directories. A test process is only ever used for one environment, so the cache
never needs invalidating.
"""
function scratch_env(project_path::AbstractString, package_name::AbstractString)
    key = (abspath(project_path), String(package_name))

    cached = get(_SCRATCH_ENVS, key, nothing)
    cached === nothing || return cached

    env = materialize_scratch_env(key[1], key[2])
    _SCRATCH_ENVS[key] = env
    return env
end

function _find_env_file(dir::AbstractString, names)
    for name in names
        path = joinpath(dir, name)
        isfile(path) && return path
    end
    return nothing
end

_abs_path(base::AbstractString, path::AbstractString) =
    isabspath(path) ? normpath(path) : normpath(joinpath(base, path))

# Manifests come in two shapes. Format 1.0 (Julia <= 1.6) is a bare mapping of
# package name to a vector of entries; format 2.0 nests that mapping under
# `[deps]` alongside top-level metadata such as `julia_version`.
function _manifest_is_v2(raw::AbstractDict)
    format = get(raw, "manifest_format", nothing)
    return format isa AbstractString && startswith(format, "2")
end

function _manifest_deps!(raw::AbstractDict)
    _manifest_is_v2(raw) || return raw

    deps = get(raw, "deps", nothing)
    if !(deps isa AbstractDict)
        deps = Dict{String,Any}()
        raw["deps"] = deps
    end
    return deps
end

function _each_manifest_entry(f, raw::AbstractDict)
    for (name, entries) in _manifest_deps!(raw)
        entries isa AbstractVector || continue
        for entry in entries
            entry isa AbstractDict && f(name, entry)
        end
    end
    return
end

# Deved dependencies record their location relative to the manifest they live
# in, so every one of them has to be rewritten before the manifest moves.
function _absolutize_manifest!(raw::AbstractDict, base::AbstractString)
    _each_manifest_entry(raw) do _, entry
        path = get(entry, "path", nothing)
        path isa AbstractString && (entry["path"] = _abs_path(base, path))
    end
    return raw
end

function _absolutize_sources!(project::AbstractDict, base::AbstractString)
    sources = get(project, "sources", nothing)
    sources isa AbstractDict || return project

    for (_, source) in sources
        source isa AbstractDict || continue
        path = get(source, "path", nothing)
        path isa AbstractString && (source["path"] = _abs_path(base, path))
    end
    return project
end

# Point `name` at `path` using whichever mechanisms this environment has: a
# `[sources]` entry (Julia 1.11+) and/or a manifest entry. Returns `true` if at
# least one of them applied, `false` if the caller has to fall back to
# `Pkg.develop`.
function _bind_package_path!(project::AbstractDict, manifest, name::AbstractString, uuid, version, path::AbstractString, entry_deps::AbstractDict)
    bound = false

    if _SUPPORTS_SOURCES
        sources = get(project, "sources", nothing)
        if !(sources isa AbstractDict)
            sources = Dict{String,Any}()
            project["sources"] = sources
        end
        sources[name] = Dict{String,Any}("path" => path)
        bound = true
    end

    if manifest !== nothing && uuid isa AbstractString
        _upsert_manifest_entry!(manifest, name, uuid, version, path, entry_deps)
        bound = true
    end

    return bound
end

# A direct dependency that is missing from the manifest is a hard error in
# `Pkg.instantiate`, so the package under test has to be listed there. Format
# 2.0 manifests already carry the root package (with `path = "."`, which
# `_absolutize_manifest!` has resolved for us); format 1.0 manifests omit it.
function _upsert_manifest_entry!(manifest::AbstractDict, name::AbstractString, uuid::AbstractString, version, path::AbstractString, entry_deps::AbstractDict)
    deps = _manifest_deps!(manifest)

    entries = get(deps, name, nothing)
    if !(entries isa AbstractVector)
        entries = Any[]
        deps[name] = entries
    end

    entry = nothing
    for candidate in entries
        if candidate isa AbstractDict && get(candidate, "uuid", nothing) == uuid
            entry = candidate
            break
        end
    end
    if entry === nothing
        entry = Dict{String,Any}()
        push!(entries, entry)
    end

    entry["uuid"] = uuid
    entry["path"] = path
    # A path-tracked package is not content-addressed; leaving a tree hash or a
    # repo behind makes Pkg look for it in the depot instead of in the folder.
    delete!(entry, "git-tree-sha1")
    delete!(entry, "repo-url")
    delete!(entry, "repo-rev")

    if version !== nothing && !haskey(entry, "version")
        entry["version"] = version
    end
    if !haskey(entry, "deps")
        # Naming a dependency the manifest does not contain makes Pkg reject the
        # whole file, so only record the ones that are actually there.
        recorded = sort!([dep for dep in keys(entry_deps) if haskey(deps, dep)])
        isempty(recorded) || (entry["deps"] = recorded)
    end

    return entry
end

# Where does `package_name` actually live? Only needed for a package under test
# that is not the source project's own package; a registered (non-path)
# dependency legitimately has no answer here and needs none, because the
# manifest already tells Pkg where to find it.
function _find_package_path(project::AbstractDict, manifest, base::AbstractString, package_name::AbstractString)
    sources = get(project, "sources", nothing)
    if sources isa AbstractDict
        source = get(sources, package_name, nothing)
        if source isa AbstractDict
            path = get(source, "path", nothing)
            path isa AbstractString && return _abs_path(base, path)
        end
    end

    if manifest !== nothing
        found = nothing
        _each_manifest_entry(manifest) do name, entry
            if found === nothing && name == package_name
                path = get(entry, "path", nothing)
                # Already absolutized by `_absolutize_manifest!`.
                path isa AbstractString && (found = path)
            end
        end
        found === nothing || return found
    end

    return nothing
end

# `[compat]` and `[sources]` entries must name something that is still listed as
# a dependency, otherwise Pkg rejects the whole project file. Dropping `[extras]`
# above orphans the compat bounds of test-only dependencies (`Test` most of all),
# which is the shape almost every real package has.
function _drop_unlisted!(project::AbstractDict, section::AbstractString, deps::AbstractDict, keep_julia::Bool)
    entries = get(project, section, nothing)
    entries isa AbstractDict || return project

    for name in collect(keys(entries))
        keep_julia && name == "julia" && continue
        haskey(deps, name) || delete!(entries, name)
    end

    isempty(entries) && delete!(project, section)
    return project
end

# Entry keys a pre-1.7 `Pkg` understands. Everything else — `weakdeps`,
# `extensions`, `entryfile`, … — postdates manifest format 1.0 and makes the old
# reader bail on the entry.
const _V1_ENTRY_KEYS = ("uuid", "version", "path", "git-tree-sha1", "repo-url", "repo-rev", "pinned", "deps")

# Rewrite a format 2.0 manifest as format 1.0: the nested `[deps]` table becomes
# the top level and the metadata keys (`julia_version`, `manifest_format`,
# `project_hash`) go away. Entry fields carry the same names in both formats, so
# the conversion is a filter rather than a translation.
function _downgrade_manifest(raw::AbstractDict)
    downgraded = Dict{String,Any}()

    for (name, entries) in _manifest_deps!(raw)
        entries isa AbstractVector || continue

        kept = Any[]
        for entry in entries
            entry isa AbstractDict || continue
            trimmed = Dict{String,Any}()
            for key in _V1_ENTRY_KEYS
                haskey(entry, key) && (trimmed[key] = entry[key])
            end
            push!(kept, trimmed)
        end

        isempty(kept) || (downgraded[name] = kept)
    end

    return downgraded
end

# Rather than guess at which manifest features which `Pkg` tolerates, write the
# candidate out and ask this one to parse it. A manifest Pkg cannot read is worse
# than no manifest at all: `Pkg.activate` itself would throw.
function _is_readable_manifest(manifest::AbstractDict)
    return mktempdir() do dir
        path = joinpath(dir, "Manifest.toml")
        _write_toml(path, manifest)
        # Old Pkg logs before it throws; the caller has a fallback, so stay quiet.
        return Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            try
                Pkg.Types.read_manifest(path)
                true
            catch err
                err isa InterruptException && rethrow()
                false
            end
        end
    end
end

function _is_uuid(value)
    value isa AbstractString || return false
    try
        Base.UUID(value)
        return true
    catch
        return false
    end
end

# `Base.collect_preferences` is handed a UUID and has to turn it into the package
# *name* that preferences are keyed by, which it does by searching the project
# file of the environment it is looking at (`Base.get_uuid_name`). An environment
# that does not name the package therefore contributes no preferences for it, no
# matter what its `LocalPreferences.toml` says — so the carrier has to reproduce
# the source environment's name/UUID mappings.
#
# `[extras]` is searched for those mappings on every Julia that has preferences
# at all (1.6 onwards) and is never consulted when loading code, which makes it
# the one section that carries the mapping without putting the carrier in the way
# of an `import`.
function _preference_owners(project::AbstractDict)
    owners = Dict{String,Any}()

    name = get(project, "name", nothing)
    uuid = get(project, "uuid", nothing)
    name isa AbstractString && _is_uuid(uuid) && (owners[name] = uuid)

    for section in ("deps", "extras", "weakdeps")
        entries = get(project, section, nothing)
        entries isa AbstractDict || continue
        for (dep_name, dep_uuid) in entries
            # A malformed entry would make `Base.get_uuid_name` throw, and the
            # carrier is consulted for every preference lookup in the process —
            # including ones that have nothing to do with the user's code.
            _is_uuid(dep_uuid) && (owners[dep_name] = dep_uuid)
        end
    end

    return owners
end

"""
    materialize_preferences_carrier(preferences, owners, local_preferences) -> Union{Nothing,String}

Build an environment directory that carries the source environment's preferences
and nothing else, and return it — or `nothing` when there are no preferences to
carry.

`preferences` is the source project's `[preferences]` table (the lower of the two
preference tiers) or `nothing`, `owners` the name/UUID mappings from
[`_preference_owners`](@ref), and `local_preferences` the path to the source
environment's `LocalPreferences.toml`, or `nothing`.

The point of the directory is to be appended to `LOAD_PATH`: `Base` resolves
preferences by walking `Base.load_path()`, and passes that same list on to every
precompilation subprocess, so an entry there survives `TestEnv.activate`
replacing the active project — where a file next to the scratch project does not.
Being last in `LOAD_PATH` makes it the lowest priority, so anything the test
environment itself declares still wins.

Both tiers are copied over separately rather than merged, which leaves the
merging — including `__clear__` entries and nested tables — to the same
`Base.collect_preferences` that would have run on the source environment. The
directory declares no dependencies and has no manifest, so it can never satisfy
an `import`; it only ever contributes preferences.
"""
function materialize_preferences_carrier(
    preferences::Union{Nothing,AbstractDict},
    owners::AbstractDict,
    local_preferences::Union{Nothing,AbstractString},
)
    preferences === nothing && local_preferences === nothing && return nothing

    dir = mktempdir()
    @static if VERSION < v"1.3.0"
        atexit(() -> Base.rm(dir; recursive=true, force=true))
    end

    # `Base.env_project_file` only recognizes a directory as an environment when
    # it holds a project file, so this is written even when there is nothing to
    # put in it.
    carrier = Dict{String,Any}()
    isempty(owners) || (carrier["extras"] = owners)
    preferences === nothing || (carrier["preferences"] = preferences)
    _write_toml(joinpath(dir, "Project.toml"), carrier)

    local_preferences === nothing || cp(local_preferences, joinpath(dir, "LocalPreferences.toml"))

    return dir
end

function _write_toml(path::AbstractString, data::AbstractDict)
    open(path, "w") do io
        Pkg.TOML.print(io, data)
    end
    return path
end

"""
    materialize_scratch_env(project_path, package_name) -> ScratchEnv

Build a scratch environment mirroring the one at `project_path` and return it.
The environment at `project_path` is only ever read.

The result is safe to `Pkg.activate` before calling `TestEnv.activate(package_name)`:
every write TestEnv performs then lands in the scratch directory or in TestEnv's
own temporary directory, never in the user's folder.

When the source environment has a manifest it is copied over (with relative
paths made absolute), so the test environment resolves against exactly the
versions the user has pinned. When it does not — or when the manifest is in a
format this Julia cannot read and cannot be downgraded — there is nothing to
preserve and TestEnv's `Pkg.instantiate` resolves one into the scratch directory.
"""
function materialize_scratch_env(project_path::AbstractString, package_name::AbstractString)
    src_dir = abspath(project_path)

    project_file = _find_env_file(src_dir, _PROJECT_NAMES)
    manifest_file = _find_env_file(src_dir, _MANIFEST_NAMES)

    project = project_file === nothing ? Dict{String,Any}() : Pkg.TOML.parsefile(project_file)
    manifest = manifest_file === nothing ? nothing : Pkg.TOML.parsefile(manifest_file)

    # The recorded hash is of the source project's dependency list, which the
    # wrapper's differs from. Pkg only uses it to decide whether to print a
    # "dependencies have changed" warning and treats its absence as "unknown" —
    # cheaper and more portable than recomputing it. Dropped up front so that a
    # malformed hash cannot fail the readability check below.
    manifest === nothing || delete!(manifest, "project_hash")

    # Captured before the sections they read are rewritten below.
    source_preferences = get(project, "preferences", nothing)
    source_preferences isa AbstractDict || (source_preferences = nothing)
    preference_owners = _preference_owners(project)

    # The user may well have resolved their environment on a newer Julia than the
    # one under test — running a package across a version matrix is the whole
    # point of configuring several — so the manifest can easily be in a format
    # this `Pkg` predates. Convert what can be converted, and drop what cannot;
    # an environment with no manifest simply resolves one in the scratch
    # directory, which is what used to happen for every environment.
    if manifest !== nothing && VERSION < v"1.7.0" && _manifest_is_v2(manifest)
        manifest = _downgrade_manifest(manifest)
    end
    if manifest !== nothing && !_is_readable_manifest(manifest)
        manifest = nothing
    end

    # Both have to happen before anything moves: deved paths and `[sources]`
    # paths are recorded relative to the file they appear in.
    manifest === nothing || _absolutize_manifest!(manifest, src_dir)
    _absolutize_sources!(project, src_dir)

    root_name = get(project, "name", nothing)
    root_uuid = get(project, "uuid", nothing)
    root_version = get(project, "version", nothing)

    deps = get(project, "deps", nothing)
    if !(deps isa AbstractDict)
        deps = Dict{String,Any}()
        project["deps"] = deps
    end

    # The dependency list the source project's package was resolved against,
    # captured before we add the package itself to it.
    source_deps = copy(deps)

    develop_path = nothing

    if root_name isa AbstractString && root_uuid isa AbstractString
        deps[root_name] = root_uuid
        bound = _bind_package_path!(project, manifest, root_name, root_uuid, root_version, src_dir, source_deps)
        bound || (develop_path = src_dir)
    end

    # The package under test may be a *different* package that this environment
    # devs — the shape a monorepo produces when a workspace package's tests run
    # against the root project. Nothing to do if we cannot place it: either it is
    # the root package we just handled, or it is a registered dependency that the
    # manifest already resolves.
    if package_name != "" && package_name != root_name && _SUPPORTS_SOURCES && haskey(deps, package_name)
        package_path = _find_package_path(project, manifest, src_dir, package_name)
        if package_path !== nothing
            sources = get(project, "sources", nothing)
            if !(sources isa AbstractDict)
                sources = Dict{String,Any}()
                project["sources"] = sources
            end
            sources[package_name] = Dict{String,Any}("path" => package_path)
        end
    end

    for key in _STRIPPED_PROJECT_KEYS
        delete!(project, key)
    end

    _SUPPORTS_SOURCES || delete!(project, "sources")

    _drop_unlisted!(project, "compat", deps, true)
    _drop_unlisted!(project, "sources", deps, false)

    env_dir = mktempdir()
    @static if VERSION < v"1.3.0"
        # `mktempdir` only registers an atexit cleanup from Julia 1.3 on.
        atexit(() -> Base.rm(env_dir; recursive=true, force=true))
    end

    _write_toml(joinpath(env_dir, "Project.toml"), project)
    manifest === nothing || _write_toml(joinpath(env_dir, "Manifest.toml"), manifest)

    # Preferences.jl resolves `LocalPreferences.toml` next to the active project
    # file, so leaving it behind would silently drop the user's local settings
    # for the duration of the test run.
    local_preferences = _find_env_file(src_dir, _LOCAL_PREFERENCES_NAMES)
    local_preferences === nothing || cp(local_preferences, joinpath(env_dir, "LocalPreferences.toml"))

    # That copy only covers the stretch where the scratch environment is the
    # active one. `TestEnv.activate` takes that away again, hence the carrier.
    preferences_dir = materialize_preferences_carrier(source_preferences, preference_owners, local_preferences)

    return ScratchEnv(env_dir, develop_path, preferences_dir)
end
