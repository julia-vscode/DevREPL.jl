# A test item that a cooperative kill cannot end. On POSIX it ignores SIGTERM outright; on
# every platform it then spins without ever yielding, so the test process cannot even get
# around to noticing that its controller is gone. Only SIGKILL (TerminateProcess on
# Windows) can stop it. Timing is bounded so a leaked process is not around forever.
@testitem "ignores sigterm and spins" begin
    if !Sys.iswindows()
        SIG_IGN = Ptr{Cvoid}(1)
        ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), Cint(15), SIG_IGN)
    end
    println("spinning")
    flush(stdout)
    t0 = time()
    while time() - t0 < 300
    end
    @test true
end
