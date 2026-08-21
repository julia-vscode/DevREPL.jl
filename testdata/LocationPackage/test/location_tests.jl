# Fixture for the test that a failure is never reported at a file that is not there.
#
# `@test_warn` expands to a `@test` inside the `Test` stdlib, so `Test` records the failure
# at the location of that inner `@test`. On a Julia built by the build bots that path does
# not exist on the machine running the tests, and VS Code answers a click on the failure
# with "The editor could not be opened because the file was not found"
# (julia-testitems/TestItemRunner.jl#25, JuliaLang/julia#47033).

@testitem "warn location" begin
    @test_warn "a warning nobody emits" nothing
end
