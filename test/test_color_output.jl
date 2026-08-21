@testitem "Test item output carries color when the environment asks for it" setup=[TestHelpers] begin
    # A test process writes to a pipe, so Julia turns color off unless it is told
    # otherwise, and nothing a test item prints can carry it
    # (julia-testitems/TestItemControllers.jl#11).
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "ColorPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "colored output", discovered.items)
    @test length(items) == 1

    result = TestHelpers.run_testrun(items, discovered.setups; color=true, TestHelpers._env_kwargs(discovered)...)

    @test length(filter(e -> e.event == :passed, result.events)) == 1

    item_output = join(values(result.outputs))
    @test occursin("a red line", item_output)
    @test occursin('\e', item_output)

    # Both streams carry the escapes through untouched. Rendering them, or stripping them
    # for a view that cannot show them — a VS Code `OutputChannel` renders them as garbage —
    # is the client's call, not ours.
    process_output = join(join(chunks) for chunks in values(result.process_output))
    @test occursin('\e', process_output)
end

@testitem "Test item output has no color by default" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "ColorPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "colored output", discovered.items)

    result = TestHelpers.run_testrun(items, discovered.setups; TestHelpers._env_kwargs(discovered)...)

    @test length(filter(e -> e.event == :passed, result.events)) == 1

    item_output = join(values(result.outputs))
    @test occursin("a red line", item_output)
    @test !occursin('\e', item_output)

    process_output = join(join(chunks) for chunks in values(result.process_output))
    @test !occursin('\e', process_output)
end

@testitem "A test environment's color setting keeps processes apart" begin
    using TestItemControllers: TestEnvironment
    using TestItemControllers: ProcessEnv

    make(color) = TestEnvironment("id", "julia", String[], nothing,
        Dict{String,Union{String,Nothing}}(), "Normal", "Pkg", "file:///pkg", nothing, nothing, nothing, color)

    @test ProcessEnv(make(true)) != ProcessEnv(make(false))
    @test ProcessEnv(make(true)) == ProcessEnv(make(true))
    @test hash(ProcessEnv(make(true))) != hash(ProcessEnv(make(false)))
end
