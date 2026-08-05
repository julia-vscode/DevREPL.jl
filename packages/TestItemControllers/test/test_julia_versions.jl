@testitem "Run tests on multiple Julia versions" tags=[:comprehensive_platform] setup=[TestHelpers] begin
    using TestItemControllers: JSON

    config = try
        JSON.parse(read(`juliaup api getconfig1`, String))
    catch e
        error("Failed to query juliaup. Is juliaup installed? Error: $e")
    end
    installed_channels = Set{String}()
    push!(installed_channels, config["DefaultChannel"]["Name"])
    for ch in get(config, "OtherChannels", [])
        push!(installed_channels, ch["Name"])
    end

    versions = ["1.0", "1.1", "1.2", "1.3", "1.4", "1.5", "1.6", "1.7", "1.8", "1.9", "1.10", "1.11", "1.12"]

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "BasicPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    target_labels = ("add works", "greet works", "failing test", "erroring test")
    items = filter(i -> i.label in target_labels, discovered.items)
    @test length(items) == 4

    for version in versions
        version in installed_channels || error("Julia $version is not installed. Install it with: juliaup add $version")
        version == "1.4" && Sys.isapple() && continue

        @testset "Julia $version" begin
            result = TestHelpers.run_testrun(items, discovered.setups, discovered; julia_cmd="julia", julia_args=["+$version"], timeout=600)

            passed_events = filter(e -> e.event == :passed, result.events)
            failed_events = filter(e -> e.event == :failed, result.events)
            errored_events = filter(e -> e.event == :errored, result.events)
            skipped_events = filter(e -> e.event == :skipped, result.events)

            @test length(passed_events) == 2
            @test length(failed_events) == 1
            @test length(failed_events[1].messages) >= 1
            @test length(errored_events) == 1
            @test length(errored_events[1].messages) >= 1
            @test occursin("intentional error", errored_events[1].messages[1].message)
            @test length(skipped_events) == 0
        end
    end
end
