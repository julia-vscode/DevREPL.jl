# Shared registry of the vendored package trees in `packages/`.
#
# Every tree is a squashed git subtree. Two flavors:
#
#   * `TAGGED_SUBTREES` track upstream releases, i.e. the newest `vX.Y.Z` tag.
#   * `BRANCH_SUBTREES` track the tip of an upstream branch. These are the packages we
#     develop in lockstep with DevREPL, which is why their vendored `Project.toml`
#     carries a `-DEV` version.

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

"""
Vendored trees that follow upstream releases: prefix => (github location, pinned tag).

The pinned tag records the release the tree was last pulled from, so that a fresh
checkout can be reproduced. `update_vendored_packages.jl` moves them to the newest tag.
"""
const TAGGED_SUBTREES = [
    "packages/AutoHashEquals"     => ("JuliaServices/AutoHashEquals.jl", "v2.2.0"),
    "packages/CancellationTokens" => ("davidanthoff/CancellationTokens.jl", "v2.3.0"),
    "packages/CSTParser"          => ("julia-vscode/CSTParser.jl", "v3.5.0"),
    "packages/ExceptionUnwrapping" => ("NHDaly/ExceptionUnwrapping.jl", "v0.1.11"),
    "packages/Glob"               => ("vtjnash/Glob.jl", "v1.5.0"),
    "packages/JuliaSyntax"        => ("JuliaLang/JuliaSyntax.jl", "v1.0.2"),
    "packages/MacroTools"         => ("FluxML/MacroTools.jl", "v0.5.16"),
    "packages/PrecompileTools"    => ("JuliaLang/PrecompileTools.jl", "v1.3.4"),
    "packages/ProgressMeter"      => ("timholy/ProgressMeter.jl", "v1.11.0"),
    "packages/ReplMaker"          => ("MasonProtter/ReplMaker.jl", "v0.2.7"),
    "packages/Scratch"            => ("JuliaPackaging/Scratch.jl", "v1.3.0"),
    "packages/Tokenize"           => ("JuliaLang/Tokenize.jl", "v0.5.29"),
]

"""
Vendored trees that follow a branch: prefix => (github location, branch).

These are pulled unconditionally, because there is no version number that tells us
whether the branch has moved on.
"""
const BRANCH_SUBTREES = [
    "packages/JuliaWorkspaces"      => ("julia-vscode/JuliaWorkspaces.jl", "main"),
    "packages/Salsa"                => ("julia-vscode/Salsa.jl", "main"),
    "packages/TestItemControllers"  => ("julia-vscode/TestItemControllers.jl", "main"),
    "packages/TestItemDetection"    => ("julia-vscode/TestItemDetection.jl", "main"),
]

"""
Packages deliberately excluded from automated updates, with the reason why.
"""
const UPDATE_EXCLUSIONS = Dict{String,String}()

git(args...; dir=REPO_ROOT) = run(addenv(Cmd(`git $(collect(args))`, dir=dir), "GIT_MERGE_AUTOEDIT" => "no"))

"""
    remote_tags(location)

All `vX.Y.Z` tags of a GitHub repository, as `VersionNumber`s. Uses `git ls-remote` so
that no GitHub API token is required.
"""
function remote_tags(location::AbstractString)
    out = read(`git ls-remote --tags --refs https://github.com/$location`, String)
    versions = VersionNumber[]
    for line in eachsplit(out, '\n')
        m = match(r"refs/tags/v(\d+\.\d+\.\d+)$", strip(line))
        m === nothing || push!(versions, VersionNumber(m[1]))
    end
    return versions
end

function vendored_version(prefix)
    m = match(r"(?m)^version\s*=\s*\"([^\"]+)\"", read(joinpath(REPO_ROOT, prefix, "Project.toml"), String))
    m === nothing && error("No version found in $prefix/Project.toml")
    return VersionNumber(m[1])
end
