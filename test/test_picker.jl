@testitem "candidate collection" setup=[ReplHelper] begin
    using JuliaWorkspaces
    jw = JuliaWorkspaces.workspace_from_folders([ReplHelper.PRECOMPILEDATA])
    cands = DevREPL._collect_testitem_candidates(jw)
    @test length(cands) == 3
    @test Set(c.name for c in cands) ==
        Set(["precompile pass", "precompile fail", "precompile error"])
    @test all(c -> endswith(c.filepath, "precompile_tests.jl"), cands)
    @test all(c -> c.line > 0, cands)
end

@testitem "fuzzy sort ranks the best match first" begin
    cands = [
        (name="alpha beta", tags=Symbol[], filepath="a.jl", line=1),
        (name="gamma delta", tags=Symbol[], filepath="b.jl", line=1),
        (name="alpaca", tags=Symbol[], filepath="c.jl", line=1),
    ]
    sorted = DevREPL._fuzzy_sort("alpha", cands)
    # "alpha" is a subsequence of "alpha beta" only ("alpaca" is missing the h)
    @test [c.name for c in sorted] == ["alpha beta"]

    # Empty query keeps everything in order
    @test DevREPL._fuzzy_sort("", cands) == cands
end

@testitem "fuzzy sort falls back to substring matches on tags and files" begin
    cands = [
        (name="one", tags=[:integration], filepath="x.jl", line=1),
        (name="two", tags=Symbol[], filepath="y.jl", line=1),
    ]
    sorted = DevREPL._fuzzy_sort("integration", cands)
    @test length(sorted) == 1
    @test sorted[1].name == "one"
end

@testitem "candidate labels include tags and location" begin
    c = (name="my test", tags=[:fast, :unit], filepath=joinpath(pwd(), "test", "t.jl"), line=7)
    label = DevREPL._candidate_label(c, pwd())
    @test occursin("my test", label)
    @test occursin("[fast, unit]", label)
    @test occursin(":7", label)
end

@testitem "pick requires a terminal" setup=[ReplHelper] begin
    out = ReplHelper.run_command("test pick")
    @test occursin("needs an interactive terminal", out)
end
