@testmodule ChattySetup begin
    println("CHATTY_SETUP_MARKER")
    const VALUE = 7
end

@testitem "chatty consumer one" setup=[ChattySetup] begin
    @test ChattySetup.VALUE == 7
end

@testitem "chatty consumer two" setup=[ChattySetup] begin
    @test ChattySetup.VALUE == 7
end

@testitem "chatty consumer three" setup=[ChattySetup] begin
    @test ChattySetup.VALUE == 7
end

@testmodule LoudSetup begin
    # Well over the 32 KiB replay cap, so the replayed copy must be truncated.
    for i in 1:2000
        println("LOUD_LINE_", i, "_", repeat("x", 40))
    end
    const VALUE = 1
end

@testitem "loud consumer" setup=[LoudSetup] begin
    @test LoudSetup.VALUE == 1
end
