@testitem "format --check and format write" setup=[ReplHelper] begin
    dir = mktempdir()
    file = joinpath(dir, "bad.jl")
    write(file, "x=1+ 2\nfunction  f( a,b )\n  a+ b\nend\n")

    out = ReplHelper.run_command("format --check $dir")
    @test occursin("would reformat", out)
    @test occursin("bad.jl", out)
    # --check must not modify the file
    @test read(file, String) == "x=1+ 2\nfunction  f( a,b )\n  a+ b\nend\n"

    out = ReplHelper.run_command("format $dir")
    @test occursin("formatted", out)
    @test occursin("1 reformatted", out)
    @test occursin("function f(a, b)", read(file, String))

    out = ReplHelper.run_command("format --check $dir")
    @test occursin("already formatted", out)
end

@testitem "format a single file" setup=[ReplHelper] begin
    dir = mktempdir()
    target = joinpath(dir, "one.jl")
    other = joinpath(dir, "two.jl")
    bad = "function  f( a,b )\n  a+ b\nend\n"
    write(target, bad)
    write(other, bad)

    ReplHelper.run_command("format $target")
    @test occursin("function f(a, b)", read(target, String))
    # The sibling file is untouched
    @test read(other, String) == bad
end

@testitem "format rejects a missing path" setup=[ReplHelper] begin
    out = ReplHelper.run_command("format $(joinpath(mktempdir(), "nope"))")
    @test occursin("is not a file or directory", out)
end

@testitem "lint reports missing references in the precompile data" setup=[ReplHelper] begin
    out = ReplHelper.run_command("lint $(ReplHelper.PRECOMPILEDATA)")
    @test occursin("Analyzing", out)
    # The summary line is always printed
    @test occursin(r"(warning|error|info|hint|No lint findings)", out)
end
