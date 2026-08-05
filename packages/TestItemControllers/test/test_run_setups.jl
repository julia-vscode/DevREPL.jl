@testitem "Test with module setup" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "SetupPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Filter to the test item that uses ConfigSetup
    setup_items = filter(i -> i.label == "transform with module setup", discovered.items)
    @test length(setup_items) == 1
    @test "ConfigSetup" in setup_items[1].test_setups

    # Include the necessary setups
    relevant_setups = filter(s -> s.name in setup_items[1].test_setups, discovered.setups)
    @test length(relevant_setups) >= 1

    result = TestHelpers.run_testrun(setup_items, discovered.setups, discovered)

    passed_events = filter(e -> e.event == :passed, result.events)
    failed_events = filter(e -> e.event == :failed, result.events)
    errored_events = filter(e -> e.event == :errored, result.events)

    @test length(passed_events) == 1
    @test length(failed_events) == 0
    @test length(errored_events) == 0
end

@testitem "Test with snippet setup" setup=[TestHelpers] begin
    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "SetupPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    # Filter to the test item that uses SharedSnippet
    snippet_items = filter(i -> i.label == "uses snippet setup", discovered.items)
    @test length(snippet_items) == 1

    result = TestHelpers.run_testrun(snippet_items, discovered.setups, discovered)

    passed_events = filter(e -> e.event == :passed, result.events)
    @test length(passed_events) == 1
end
