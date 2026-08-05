@testitem "add works" begin
    using BasicPackage
    @test add(1, 2) == 3
    @test add(0, 0) == 0
    @test add(-1, 1) == 0
end

@testitem "greet works" begin
    using BasicPackage
    @test greet() == "Hello from BasicPackage!"
end

@testitem "failing test" begin
    @test 1 == 2
end

@testitem "erroring test" begin
    error("intentional error")
end

@testitem "output test" begin
    println("hello from output test")
    println("second line of output")
    @test true
end

@testitem "slow test" begin
    sleep(60)
    @test true
end

@testitem "erroring test deep stack" begin
    function inner()
        error("deep error")
    end
    function middle()
        inner()
    end
    function outer()
        middle()
    end
    outer()
end

@testitem "erroring test via package" begin
    using BasicPackage
    buggy_func()
end

@testitem "failing test multiple" begin
    @test 1 == 2
    @test 3 == 4
end

@testitem "test error inside @test" begin
    @test error("inside test macro")
end

@testitem "test error inside @test deep stack" begin
    function inner_test_func()
        error("deep @test error")
    end
    function middle_test_func()
        inner_test_func()
    end
    function outer_test_func()
        middle_test_func()
    end
    @test outer_test_func()
end

@testitem "exit crash" begin
    exit()
end

@testitem "abort crash" begin
    ccall(:abort, Cvoid, ())
end
