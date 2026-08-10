@testitem "run_tests end to end on the precompile data" setup=[ReplHelper] tags=[:integration] begin
    result = DevREPL.run_tests(ReplHelper.PRECOMPILEDATA;
        return_results=true, max_workers=1, timeout=300, progress_ui=:none,
        fail_on_detection_error=false)
    try
        @test length(result.testitems) == 3
        statuses = Dict(ti.name => ti.profiles[1].status for ti in result.testitems)
        @test statuses["precompile pass"] == :passed
        @test statuses["precompile fail"] == :failed
        @test statuses["precompile error"] == :errored

        # The failing item carries a message with a location
        fail_item = only(ti for ti in result.testitems if ti.name == "precompile fail")
        msgs = fail_item.profiles[1].messages
        @test msgs !== missing && !isempty(msgs)
        @test msgs[1].line > 0

        # 'test failed' can compute the failing selection from this run
        failing = Set{String}()
        for ti in result.testitems
            if any(p -> p.status in (:failed, :errored), ti.profiles)
                push!(failing, ti.name)
            end
        end
        @test failing == Set(["precompile fail", "precompile error"])
    finally
        DevREPL.kill_test_processes()
    end
end
