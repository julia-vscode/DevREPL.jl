@testitem "A failure is never located at a file that is not on this machine" setup=[TestHelpers] begin
    # `@test_warn` expands to a `@test` inside the `Test` stdlib, so the failure `Test`
    # records points at the stdlib's *build* path, which does not exist on a Julia that
    # came from the build bots. Reporting it verbatim is what makes VS Code answer a click
    # on the failure with "the file was not found"
    # (julia-testitems/TestItemRunner.jl#25, JuliaLang/julia#47033).
    #
    # The invariant asserted here — every location we hand out names a file that exists —
    # is the one worth having, and it holds on a locally built Julia too, where the stdlib
    # path happens to resolve.
    using TestItemControllers: uri2filepath

    pkg_path = joinpath(TestHelpers.TESTDATA_DIR, "LocationPackage")
    discovered = TestHelpers.discover_test_items(pkg_path)

    items = filter(i -> i.label == "warn location", discovered.items)
    @test length(items) == 1

    result = TestHelpers.run_testrun(items, discovered.setups, discovered)

    failed_events = filter(e -> e.event == :failed, result.events)
    @test length(failed_events) == 1

    messages = failed_events[1].messages
    @test length(messages) >= 1

    for m in messages
        @test m.uri !== nothing
        @test isfile(uri2filepath(m.uri))

        m.stack_trace === nothing && continue
        for frame in m.stack_trace
            # A frame whose file is not here carries no uri at all, so that the client
            # renders it as text rather than as a link that cannot be followed
            frame.uri === nothing && continue
            @test isfile(uri2filepath(frame.uri))
        end
    end
end
