# Update the vendored `packages/` trees to their newest upstream state.
#
#     julia scripts/update_vendored_packages.jl          # report only
#     julia scripts/update_vendored_packages.jl --apply  # also pull the subtrees
#
# Release-tracking trees move to the newest `vX.Y.Z` tag, branch-tracking trees are
# pulled from the tip of their branch.
#
# After applying, bump the pinned tags in `vendored_packages.jl` so that a fresh
# bootstrap reproduces the same trees.

include("vendored_packages.jl")

const APPLY = "--apply" in ARGS

outdated = Tuple{String,String,String}[]  # prefix, location, ref to pull

for (prefix, (location, _)) in TAGGED_SUBTREES
    if haskey(UPDATE_EXCLUSIONS, prefix)
        println("$prefix: skipped — $(UPDATE_EXCLUSIONS[prefix])")
        continue
    end

    current = vendored_version(prefix)
    tags = remote_tags(location)
    if isempty(tags)
        @warn "No release tags found upstream" prefix location
        continue
    end
    latest = maximum(tags)

    println("$prefix: vendored $current, latest release $latest")
    latest > current && push!(outdated, (prefix, location, "v$latest"))
end

for (prefix, (location, branch)) in BRANCH_SUBTREES
    if haskey(UPDATE_EXCLUSIONS, prefix)
        println("$prefix: skipped — $(UPDATE_EXCLUSIONS[prefix])")
        continue
    end

    println("$prefix: tracking branch $branch, always pulled")
    push!(outdated, (prefix, location, branch))
end

if isempty(outdated)
    println("\nEverything is up to date.")
elseif !APPLY
    println("\n$(length(outdated)) package(s) would be pulled. Re-run with --apply to do it.")
else
    for (prefix, location, ref) in outdated
        @info "Pulling subtree" prefix ref
        git("subtree", "pull", "--prefix", prefix, "https://github.com/$location", ref, "--squash")
    end
    println("\nPulled $(length(outdated)) package(s). Remember to bump the pinned tags in scripts/vendored_packages.jl.")
end
