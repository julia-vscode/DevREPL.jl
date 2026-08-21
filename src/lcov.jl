"""
LCOV export for the coverage carried on a [`TestrunResult`](@ref).

`CoverageTools` is vendored under `packages/`, which is an implementation detail of this
package — consumers that want an `lcov.info` file should go through here rather than
reaching into the vendored copy and having to know how our URIs map onto file paths.
"""

"""
    write_lcov(io_or_path, result::TestrunResult; root=nothing)

Write the merged coverage of `result` in LCOV info format, the format `genhtml`,
Codecov, Coveralls and friends consume.

Returns `false` and writes nothing when the run collected no coverage — that is the normal
outcome for a run that was not started in coverage mode, not an error.

`root` is a directory path or `file:` URI to relativize the `SF:` paths against; without
it they are absolute. Coverage services match `SF:` paths against paths in the repository,
and the absolute paths of a CI runner match nothing at all — which is one way a fully
covered package comes out at 0%. A file outside `root` keeps its absolute path rather than
a `..`-heavy one, the same choice [`write_junit_xml`](@ref) makes.

Paths always use `/` separators, so a Windows leg and a Linux leg of the same matrix
contribute the same file names to a merged report.

Entries whose URI is not a `file:` URI are skipped.
"""
function write_lcov(io::IO, result::TestrunResult; root::Union{Nothing,AbstractString}=nothing)
    fcs = _to_coverage_tools(result, root)
    fcs === nothing && return false
    CoverageTools.LCOV.write(io, fcs)
    return true
end

function write_lcov(path::AbstractString, result::TestrunResult; root::Union{Nothing,AbstractString}=nothing)
    fcs = _to_coverage_tools(result, root)
    fcs === nothing && return false
    CoverageTools.LCOV.writefile(path, fcs)
    return true
end

function _to_coverage_tools(result::TestrunResult, root::Union{Nothing,AbstractString})
    result.coverage === nothing && return nothing
    isempty(result.coverage) && return nothing

    fcs = CoverageTools.FileCoverage[]
    for fc in result.coverage
        # Shared with the JUnit writer: same relativization, same `/` separators, same
        # refusal to walk out of the root with `..`.
        filename = _report_path(fc.uri, root)
        filename === nothing && continue
        push!(fcs, CoverageTools.FileCoverage(filename, "", fc.coverage))
    end

    return isempty(fcs) ? nothing : fcs
end
