@testitem "ProcessEnv equality" begin
    using TestItemControllers: ProcessEnv

    env1 = ProcessEnv(
        "file:///project",
        "file:///package",
        "MyPkg",
        "julia",
        String[],
        nothing,
        "Run",
        Dict{String,Union{String,Nothing}}()
    )
    env2 = ProcessEnv(
        "file:///project",
        "file:///package",
        "MyPkg",
        "julia",
        String[],
        nothing,
        "Run",
        Dict{String,Union{String,Nothing}}()
    )

    @test env1 == env2
    @test isequal(env1, env2)
end

@testitem "ProcessEnv inequality" begin
    using TestItemControllers: ProcessEnv

    env1 = ProcessEnv(
        "file:///project",
        "file:///package",
        "MyPkg",
        "julia",
        String[],
        nothing,
        "Run",
        Dict{String,Union{String,Nothing}}()
    )
    env_diff_mode = ProcessEnv(
        "file:///project",
        "file:///package",
        "MyPkg",
        "julia",
        String[],
        nothing,
        "Coverage",
        Dict{String,Union{String,Nothing}}()
    )
    env_diff_pkg = ProcessEnv(
        "file:///project",
        "file:///other",
        "OtherPkg",
        "julia",
        String[],
        nothing,
        "Run",
        Dict{String,Union{String,Nothing}}()
    )

    @test env1 != env_diff_mode
    @test env1 != env_diff_pkg
    @test !isequal(env1, env_diff_mode)
end

@testitem "ProcessEnv hashing" begin
    using TestItemControllers: ProcessEnv

    env1 = ProcessEnv(nothing, "file:///pkg", "Pkg", "julia", String[], nothing, "Run", Dict{String,Union{String,Nothing}}())
    env2 = ProcessEnv(nothing, "file:///pkg", "Pkg", "julia", String[], nothing, "Run", Dict{String,Union{String,Nothing}}())
    env3 = ProcessEnv(nothing, "file:///pkg", "Pkg", "julia", String[], nothing, "Coverage", Dict{String,Union{String,Nothing}}())

    @test hash(env1) == hash(env2)
    @test hash(env1) != hash(env3)
end

@testitem "ProcessEnv as Dict key" begin
    using TestItemControllers: ProcessEnv

    env1 = ProcessEnv(nothing, "file:///pkg", "Pkg", "julia", String[], nothing, "Run", Dict{String,Union{String,Nothing}}())
    env2 = ProcessEnv(nothing, "file:///pkg", "Pkg", "julia", String[], nothing, "Run", Dict{String,Union{String,Nothing}}())

    d = Dict{ProcessEnv,Int}()
    d[env1] = 42
    @test d[env2] == 42
    @test length(d) == 1
end

@testitem "ProcessEnv with non-empty env dict" begin
    using TestItemControllers: ProcessEnv

    env1 = ProcessEnv(
        nothing, "file:///pkg", "Pkg", "julia", String[], nothing, "Run",
        Dict{String,Union{String,Nothing}}("MY_VAR" => "hello", "OTHER" => nothing)
    )
    env2 = ProcessEnv(
        nothing, "file:///pkg", "Pkg", "julia", String[], nothing, "Run",
        Dict{String,Union{String,Nothing}}("MY_VAR" => "hello", "OTHER" => nothing)
    )
    env3 = ProcessEnv(
        nothing, "file:///pkg", "Pkg", "julia", String[], nothing, "Run",
        Dict{String,Union{String,Nothing}}("MY_VAR" => "different")
    )

    @test env1 == env2
    @test isequal(env1, env2)
    @test hash(env1) == hash(env2)

    @test env1 != env3
    @test !isequal(env1, env3)
    @test hash(env1) != hash(env3)
end

@testitem "ProcessEnv with different juliaArgs" begin
    using TestItemControllers: ProcessEnv

    env1 = ProcessEnv(
        nothing, "file:///pkg", "Pkg", "julia",
        ["--optimize=2"],
        nothing, "Run", Dict{String,Union{String,Nothing}}()
    )
    env2 = ProcessEnv(
        nothing, "file:///pkg", "Pkg", "julia",
        ["--optimize=0"],
        nothing, "Run", Dict{String,Union{String,Nothing}}()
    )
    env3 = ProcessEnv(
        nothing, "file:///pkg", "Pkg", "julia",
        ["--optimize=2"],
        nothing, "Run", Dict{String,Union{String,Nothing}}()
    )

    @test env1 != env2
    @test !isequal(env1, env2)
    @test hash(env1) != hash(env2)

    @test env1 == env3
    @test isequal(env1, env3)
    @test hash(env1) == hash(env3)
end

@testitem "ProcessEnv with different juliaNumThreads" begin
    using TestItemControllers: ProcessEnv

    env_nothing = ProcessEnv(
        nothing, "file:///pkg", "Pkg", "julia", String[],
        nothing, "Run", Dict{String,Union{String,Nothing}}()
    )
    env_auto = ProcessEnv(
        nothing, "file:///pkg", "Pkg", "julia", String[],
        "auto", "Run", Dict{String,Union{String,Nothing}}()
    )
    env_four = ProcessEnv(
        nothing, "file:///pkg", "Pkg", "julia", String[],
        "4", "Run", Dict{String,Union{String,Nothing}}()
    )

    @test env_nothing != env_auto
    @test env_auto != env_four
    @test !isequal(env_nothing, env_auto)
    @test isequal(env_nothing, env_nothing)
end

@testitem "ProcessEnv with different project_uri" begin
    using TestItemControllers: ProcessEnv

    env1 = ProcessEnv(
        "file:///project1", "file:///pkg", "Pkg", "julia",
        String[], nothing, "Run", Dict{String,Union{String,Nothing}}()
    )
    env2 = ProcessEnv(
        "file:///project2", "file:///pkg", "Pkg", "julia",
        String[], nothing, "Run", Dict{String,Union{String,Nothing}}()
    )
    env_nothing = ProcessEnv(
        nothing, "file:///pkg", "Pkg", "julia",
        String[], nothing, "Run", Dict{String,Union{String,Nothing}}()
    )

    @test env1 != env2
    @test env1 != env_nothing
end
