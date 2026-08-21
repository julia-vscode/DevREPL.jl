# One test item per Julia minor version, so the runner can execute them in parallel.
#
# This is safe with respect to precompilation even for the old versions that predate Base's
# pidfile locking of cache files (added in 1.10): each minor version has its own
# `compiled/vX.Y` tree, so two of these items never write the same cache file. The depot-wide
# state they *would* otherwise share — Pkg's usage logs — is isolated by the private layered
# depot that `TestHelpers.check_julia_version` sets up per version.
#
# The blocks are spelled out rather than generated in a loop because test items are discovered
# by static parsing.

@testitem "Julia 1.0 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.0")
end

@testitem "Julia 1.1 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.1")
end

@testitem "Julia 1.2 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.2")
end

@testitem "Julia 1.3 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.3")
end

@testitem "Julia 1.4 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.4")
end

@testitem "Julia 1.5 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.5")
end

@testitem "Julia 1.6 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.6")
end

@testitem "Julia 1.7 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.7")
end

@testitem "Julia 1.8 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.8")
end

@testitem "Julia 1.9 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.9")
end

@testitem "Julia 1.10 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.10")
end

@testitem "Julia 1.11 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.11")
end

@testitem "Julia 1.12 platform" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    TestHelpers.check_julia_version("1.12")
end
