# Probes for the module teardown that frees whatever a test item bound to a global.
#
# Every test item runs in a module of its own, and Julia cannot unload a module, so
# without the teardown the array below stays reachable for the life of the test process
# (julia-testitems/TestItemRunner.jl#65).
#
# The two items have to run in this order on the same test process, which is why the test
# drives them as two consecutive test runs rather than as one run of two items: the
# controller keeps its remaining work in a `Dict`, so the order within a single run is not
# something a test can rely on.
#
# The probe lives in `Main` rather than in the item's own module precisely because `Main`
# is what the teardown does *not* touch.

@testitem "memory probe: bind" begin
    leaked = zeros(UInt8, 8_000_000)
    Core.eval(Main, :(MEMORY_PROBE = $(WeakRef(leaked))))
    @test length(leaked) == 8_000_000
end

@testitem "memory probe: check" begin
    GC.gc(true)
    GC.gc(true)

    @test isdefined(Main, :MEMORY_PROBE)
    @test Main.MEMORY_PROBE.value === nothing
end
