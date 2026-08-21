@testitem "JUnit XML basic structure" begin
    using TestItemControllers: write_junit_xml
    using TestItemControllers.Results

    result = TestrunResult(
        TestrunResultDefinitionError[],
        [
            TestrunResultTestitem(
                "passing item",
                "file:///c%3A/pkg/test/a.jl",
                [TestrunResultTestitemProfile("Julia 1.12", :passed, 12.5, nothing, nothing)],
            ),
            TestrunResultTestitem(
                "failing item",
                "file:///c%3A/pkg/test/a.jl",
                [TestrunResultTestitemProfile(
                    "Julia 1.12",
                    :failed,
                    873.0,
                    [TestrunResultMessage("Test Failed at a.jl:5", "1", "2", "file:///c%3A/pkg/test/a.jl", 5, 9, nothing)],
                    nothing,
                )],
            ),
            TestrunResultTestitem(
                "erroring item",
                "file:///c%3A/pkg/test/b.jl",
                [TestrunResultTestitemProfile("Julia 1.12", :errored, 5.0,
                    [TestrunResultMessage("BoundsError", nothing, nothing, "file:///c%3A/pkg/test/b.jl", 2, 1, nothing)],
                    nothing)],
            ),
            TestrunResultTestitem(
                "skipped item",
                "file:///c%3A/pkg/test/b.jl",
                [TestrunResultTestitemProfile("Julia 1.12", :skipped, nothing, nothing, nothing)],
            ),
            TestrunResultTestitem(
                "crashed item",
                "file:///c%3A/pkg/test/b.jl",
                [TestrunResultTestitemProfile("Julia 1.12", :crash, nothing, nothing, nothing)],
            ),
        ],
        Dict{String,String}(),
    )

    io = IOBuffer()
    write_junit_xml(io, result; root="file:///c%3A/pkg")
    xml = String(take!(io))

    @test startswith(xml, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
    @test occursin("<testsuites tests=\"5\"", xml)
    @test occursin("failures=\"1\"", xml)
    @test occursin("skipped=\"1\"", xml)
    # errored + crash both count as errors
    @test occursin("errors=\"2\"", xml)

    # One testsuite per file, named by the path relative to the root, `/`-separated.
    @test occursin("<testsuite name=\"test/a.jl\"", xml)
    @test occursin("<testsuite name=\"test/b.jl\"", xml)
    @test !occursin("\\", xml)

    @test occursin("classname=\"test/a.jl\" name=\"passing item\" id=\"test/a.jl::passing item\"", xml)
    @test occursin("time=\"0.0125\"", xml)
    @test occursin("<failure message=\"Test Failed at a.jl:5\" type=\"failed\">", xml)
    @test occursin("<error message=\"BoundsError\" type=\"errored\">", xml)
    @test occursin("<skipped/>", xml)
    # A crash reports no messages, but must still produce an element or it reads as a pass.
    @test occursin("type=\"crash\"", xml)
    @test occursin("</testsuites>", xml)
end

@testitem "JUnit XML escapes XML-hostile content" begin
    using TestItemControllers: write_junit_xml
    using TestItemControllers.Results

    result = TestrunResult(
        TestrunResultDefinitionError[],
        [TestrunResultTestitem(
            "a < b & \"c\" 'd' ]]>",
            "file:///c%3A/pkg/test/a.jl",
            [TestrunResultTestitemProfile(
                "P",
                :failed,
                1.0,
                [TestrunResultMessage("expected <Int> & got ]]>", nothing, nothing, "file:///c%3A/pkg/test/a.jl", 1, 1, nothing)],
                "output with <tags> & ampersands and ]]> in it",
            )],
        )],
        Dict{String,String}(),
    )

    io = IOBuffer()
    write_junit_xml(io, result; root="file:///c%3A/pkg")
    xml = String(take!(io))

    @test !occursin("]]>", xml)
    @test occursin("]]&gt;", xml)
    @test occursin("&amp;", xml)
    @test occursin("&lt;", xml)
    @test occursin("&quot;", xml)
    @test occursin("&apos;", xml)
    # No raw `<` survives except as part of a tag we wrote ourselves.
    @test !occursin("<Int>", xml)
    @test !occursin("<tags>", xml)
end

@testitem "JUnit XML strips ANSI and keeps unicode" begin
    using TestItemControllers: write_junit_xml
    using TestItemControllers.Results

    output = "\e[31mred text\e[0m and \e[1;32mbold green\e[0m — καλά 日本語 🎉\n\e[2Kcleared"

    result = TestrunResult(
        TestrunResultDefinitionError[],
        [TestrunResultTestitem(
            "unicode ✓ item",
            "file:///c%3A/pkg/test/ünïcode.jl",
            [TestrunResultTestitemProfile("P", :passed, 1.0, nothing, output)],
        )],
        Dict{String,String}(),
    )

    io = IOBuffer()
    write_junit_xml(io, result; root="file:///c%3A/pkg")
    xml = String(take!(io))

    @test !occursin('\e', xml)
    @test occursin("red text", xml)
    @test occursin("bold green", xml)
    @test occursin("cleared", xml)
    @test occursin("— καλά 日本語 🎉", xml)
    @test occursin("unicode ✓ item", xml)
    @test occursin("<system-out>", xml)
end

@testitem "JUnit XML emits perf as properties" begin
    using TestItemControllers: write_junit_xml
    using TestItemControllers.Results

    result = TestrunResult(
        TestrunResultDefinitionError[],
        [
            TestrunResultTestitem(
                "with perf",
                "file:///c%3A/pkg/test/a.jl",
                [TestrunResultTestitemProfile("P", :passed, 1.0, nothing, nothing,
                    TestrunResultPerfStats(1.0, 2048, 17, 0.5, 100.0, nothing))],
            ),
            TestrunResultTestitem(
                "without perf",
                "file:///c%3A/pkg/test/a.jl",
                [TestrunResultTestitemProfile("P", :passed, 1.0, nothing, nothing)],
            ),
        ],
        Dict{String,String}(),
    )

    io = IOBuffer()
    write_junit_xml(io, result; root="file:///c%3A/pkg")
    xml = String(take!(io))

    @test occursin("<property name=\"elapsed_ms\" value=\"1.0\"/>", xml)
    @test occursin("<property name=\"bytes\" value=\"2048\"/>", xml)
    @test occursin("<property name=\"allocs\" value=\"17\"/>", xml)
    @test occursin("<property name=\"compile_time_ms\" value=\"100.0\"/>", xml)
    # `nothing` fields are omitted rather than written as an empty value.
    @test !occursin("recompile_time_ms", xml)
    # The item without perf is a self-closing testcase with no properties block.
    @test occursin("name=\"without perf\" id=\"test/a.jl::without perf\" time=\"0.001\"/>", xml)
end

@testitem "JUnit XML reports definition errors" begin
    using TestItemControllers: write_junit_xml
    using TestItemControllers.Results

    result = TestrunResult(
        [TestrunResultDefinitionError("Invalid testitem", "file:///c%3A/pkg/test/bad.jl", 3, 1)],
        TestrunResultTestitem[],
        Dict{String,String}(),
    )

    io = IOBuffer()
    write_junit_xml(io, result; root="file:///c%3A/pkg")
    xml = String(take!(io))

    @test occursin("<testsuite name=\"Definition errors\"", xml)
    @test occursin("type=\"definition_error\"", xml)
    @test occursin("Invalid testitem", xml)
    @test occursin("<testsuites tests=\"1\" failures=\"0\" errors=\"1\"", xml)
end

@testitem "JUnit XML without a root keeps absolute paths" begin
    using TestItemControllers: write_junit_xml
    using TestItemControllers.Results

    result = TestrunResult(
        TestrunResultDefinitionError[],
        [TestrunResultTestitem("item", "file:///c%3A/pkg/test/a.jl",
            [TestrunResultTestitemProfile("P", :passed, 1.0, nothing, nothing)])],
        Dict{String,String}(),
    )

    io = IOBuffer()
    write_junit_xml(io, result)
    xml = String(take!(io))

    @test occursin("c:/pkg/test/a.jl", xml)
end

@testitem "JUnit XML file output" begin
    using TestItemControllers: write_junit_xml
    using TestItemControllers.Results

    result = TestrunResult(
        TestrunResultDefinitionError[],
        [TestrunResultTestitem("item", "file:///c%3A/pkg/test/a.jl",
            [TestrunResultTestitemProfile("P", :passed, 1.0, nothing, nothing)])],
        Dict{String,String}(),
    )

    mktempdir() do dir
        path = joinpath(dir, "junit.xml")
        write_junit_xml(path, result; root="file:///c%3A/pkg")
        xml = read(path, String)
        @test occursin("<testsuites", xml)
        @test occursin("name=\"item\"", xml)
    end
end

@testitem "LCOV export" begin
    using TestItemControllers: write_lcov
    using TestItemControllers.Results

    empty_result = TestrunResult(TestrunResultDefinitionError[], TestrunResultTestitem[], Dict{String,String}())

    io = IOBuffer()
    @test write_lcov(io, empty_result) == false
    @test isempty(take!(io))

    covered = TestrunResult(
        TestrunResultDefinitionError[],
        TestrunResultTestitem[],
        Dict{String,String}(),
        [TestrunResultFileCoverage("file:///c%3A/pkg/src/f.jl", Union{Nothing,Int}[nothing, 3, 0, nothing])],
    )

    io = IOBuffer()
    @test write_lcov(io, covered) == true
    lcov = String(take!(io))
    @test occursin("SF:", lcov)
    @test occursin("f.jl", lcov)
    @test occursin("DA:2,3", lcov)
    @test occursin("DA:3,0", lcov)
    @test occursin("end_of_record", lcov)
end

@testitem "JUnit XML accepts a relative root" begin
    using TestItemControllers: write_junit_xml, filepath2uri
    using TestItemControllers.Results

    # `relpath` does not resolve a relative start path against the working directory, so a
    # relative root used to produce a `..`-heavy path, fail the guard in `_relative_path`,
    # and silently emit absolute machine paths as classnames instead.
    mktempdir() do dir
        # macOS hands out `/var/...`, a symlink to `/private/var/...`, and `cd` + `pwd`
        # resolve it — so without this the root and the item uris spell the same folder two
        # ways, `relpath` walks out with `..`, and the writer falls back to absolute paths.
        # The same one-folder-two-spellings disease as Windows 8.3 names, different OS.
        dir = realpath(dir)
        pkg = joinpath(dir, "pkg")
        mkpath(joinpath(pkg, "test"))
        item_uri = string(filepath2uri(joinpath(pkg, "test", "a.jl")))

        result = TestrunResult(
            TestrunResultDefinitionError[],
            [TestrunResultTestitem("item", item_uri,
                [TestrunResultTestitemProfile("P", :passed, 1.0, nothing, nothing)])],
            Dict{String,String}(),
        )

        io = IOBuffer()
        cd(dir) do
            write_junit_xml(io, result; root="pkg")
        end
        xml = String(take!(io))

        @test occursin("test/a.jl", xml)
        @test !occursin(replace(pkg, "\\" => "/"), xml)
    end
end

@testitem "LCOV export relativizes against a root" begin
    using TestItemControllers: write_lcov, filepath2uri
    using TestItemControllers.Results

    # Coverage services match `SF:` paths against paths in the repository. The absolute
    # paths of a CI runner match nothing at all, which is one way a fully covered package
    # gets reported as 0%.
    mktempdir() do dir
        dir = realpath(dir)
        pkg = joinpath(dir, "pkg")
        mkpath(joinpath(pkg, "src"))
        uri = string(filepath2uri(joinpath(pkg, "src", "f.jl")))

        result = TestrunResult(
            TestrunResultDefinitionError[],
            TestrunResultTestitem[],
            Dict{String,String}(),
            [TestrunResultFileCoverage(uri, Union{Nothing,Int}[nothing, 3, 0])],
        )

        io = IOBuffer()
        @test write_lcov(io, result; root=pkg) == true
        lcov = String(take!(io))

        @test occursin("SF:src/f.jl", lcov)
        @test !occursin(replace(pkg, "\\" => "/"), lcov)

        # ...and a relative root is resolved against the working directory, which `relpath`
        # does not do on its own.
        io = IOBuffer()
        cd(dir) do
            write_lcov(io, result; root="pkg")
        end
        @test occursin("SF:src/f.jl", String(take!(io)))
    end
end

@testitem "LCOV export keeps files outside the root absolute" begin
    using TestItemControllers: write_lcov, filepath2uri
    using TestItemControllers.Results

    # A `..`-heavy path means nothing to a coverage service, and dropping the record would
    # make a stray file look like a coverage regression rather than a stray file.
    mktempdir() do dir
        dir = realpath(dir)
        mkpath(joinpath(dir, "pkg"))
        mkpath(joinpath(dir, "elsewhere"))
        uri = string(filepath2uri(joinpath(dir, "elsewhere", "f.jl")))

        result = TestrunResult(
            TestrunResultDefinitionError[],
            TestrunResultTestitem[],
            Dict{String,String}(),
            [TestrunResultFileCoverage(uri, Union{Nothing,Int}[1])],
        )

        io = IOBuffer()
        @test write_lcov(io, result; root=joinpath(dir, "pkg")) == true
        lcov = String(take!(io))

        @test !occursin("SF:..", lcov)
        # Lowercased because `filepath2uri` lowercases the Windows drive letter on the way
        # in, and the round trip does not restore its case.
        @test occursin(lowercase(replace(joinpath(dir, "elsewhere", "f.jl"), "\\" => "/")),
            lowercase(lcov))
    end
end

@testitem "LCOV export uses forward slashes and skips non-file URIs" begin
    using TestItemControllers: write_lcov
    using TestItemControllers.Results

    # `uri2filepath` hands back a backslashed path on Windows, which no LCOV consumer
    # recognizes — a Windows leg used to contribute nothing to a merged report.
    result = TestrunResult(
        TestrunResultDefinitionError[],
        TestrunResultTestitem[],
        Dict{String,String}(),
        [
            TestrunResultFileCoverage("untitled:Untitled-1", Union{Nothing,Int}[1]),
            TestrunResultFileCoverage("file:///c%3A/pkg/src/f.jl", Union{Nothing,Int}[nothing, 3]),
        ],
    )

    io = IOBuffer()
    @test write_lcov(io, result) == true
    lcov = String(take!(io))

    @test !occursin("\\", lcov)
    @test !occursin("Untitled-1", lcov)
    @test occursin("SF:c:/pkg/src/f.jl", lcov)
end
