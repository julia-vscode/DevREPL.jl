@testitem "progress bar width is capped" begin
    p = DevREPL._make_progress_bar(100)
    # Nothing gives ProgressMeter's default, which expands to the full terminal.
    @test p.barlen isa Int
    @test 10 <= p.barlen <= 40
    # Attaching resumes at the count already reached.
    @test DevREPL._make_progress_bar(100; start=37).start == 37
end

@testitem "detach! silences a presentation" begin
    pres = DevREPL.RunPresentation(:bar; show_summary=true, show_failures=true)
    DevREPL.detach!(pres)
    @test pres.mode === :none
    @test !pres.show_summary
    @test !pres.show_failures
end

@testitem "RunPresentation defaults" begin
    pres = DevREPL.RunPresentation(:bar)
    @test pres.mode === :bar
    @test !pres.show_summary && !pres.show_failures
    @test pres.render() === nothing   # no-op until a run installs one
end

@testitem "_settle waits for a finished task and gives up on a stuck one" begin
    done_task = Threads.@spawn 1 + 1
    @test DevREPL._settle(done_task; timeout=5.0)

    stop = Threads.Atomic{Bool}(false)
    stuck = Threads.@spawn (while !stop[]; sleep(0.01); end)
    @test !DevREPL._settle(stuck; timeout=0.2)   # bounded, not hung
    stop[] = true
    wait(stuck)
end

# The presentation is what a detach flips, so a run carrying a detached one must
# stay completely silent — otherwise a backgrounded run writes over the prompt it
# just handed back, which is the bug this whole mechanism exists to prevent.
@testitem "a detached presentation makes a run silent" setup=[ReplHelper] begin
    quiet = DevREPL.RunPresentation(:none)
    out_path, out_io = mktemp()
    try
        redirect_stdio(; stdout=out_io, stderr=out_io) do
            DevREPL.run_tests(ReplHelper.PRECOMPILEDATA; presentation=quiet, max_workers=1)
        end
    finally
        close(out_io)
    end
    @test isempty(strip(read(out_path, String)))
end

@testitem "a live presentation still prints the summary" setup=[ReplHelper] begin
    live = DevREPL.RunPresentation(:none; show_summary=true)
    out_path, out_io = mktemp()
    try
        redirect_stdio(; stdout=out_io, stderr=out_io) do
            DevREPL.run_tests(ReplHelper.PRECOMPILEDATA; presentation=live, max_workers=1)
        end
    finally
        close(out_io)
    end
    @test occursin("3 tests ran", read(out_path, String))
end

# Without a TTY there are no keypresses, so the watch simply runs to completion.
@testitem "_watch_run returns :completed when the run finishes" begin
    using TestItemControllers.CancellationTokens: CancellationTokenSource
    task = Threads.@spawn (sleep(0.1); :ok)
    pres = DevREPL.RunPresentation(:none)
    @test DevREPL._watch_run(task, CancellationTokenSource(), pres) === :completed
end

@testitem "run keys decode" begin
    @test DevREPL._run_key_action(0x1b) === :cancel
    @test DevREPL._run_key_action(UInt8('b')) === :detach
    @test DevREPL._run_key_action(UInt8('B')) === :detach
    @test DevREPL._run_key_action(UInt8('x')) === :none
    @test DevREPL._run_key_action(UInt8('\n')) === :none
end

# The reported bug: `_run_blocking` returned while the run was still unwinding,
# so the summary landed after the REPL had already drawn its prompt. Capturing
# stdout only for the duration of the call turns that into a hard assertion —
# anything printed late would miss the capture entirely.
@testitem "a run prints everything before it returns" setup=[ReplHelper] begin
    out_path, out_io = mktemp()
    try
        redirect_stdio(; stdout=out_io, stderr=out_io) do
            DevREPL._run_blocking(ReplHelper.PRECOMPILEDATA, Dict{Symbol,Any}(:max_workers => 1))
        end
    finally
        close(out_io)
    end
    text = read(out_path, String)
    @test occursin("Discovered 3 test item(s)", text)
    @test occursin("3 tests ran", text)      # the summary, not stranded after the prompt
end

# The reported bug: `:completed` was stamped unconditionally, so a cancelled run
# was indistinguishable from a successful one in `test history`. Cancellation
# returns normally from the controller, so only the token can tell them apart.
@testitem "a cancelled run is recorded as cancelled" setup=[ReplHelper] begin
    using TestItemControllers.CancellationTokens: CancellationTokenSource, cancel
    cts = CancellationTokenSource()
    cancel(cts)   # already cancelled before it starts: no waiting, same code path
    DevREPL.run_tests(ReplHelper.PRECOMPILEDATA;
                      cancellation_source=cts,
                      presentation=DevREPL.RunPresentation(:none), max_workers=1)
    rec = first(DevREPL.get_run_history())
    @test rec.status === :cancelled
    @test rec.end_time !== nothing          # so history can show a duration
end

@testitem "a run that throws is recorded as errored" setup=[ReplHelper] begin
    @test_throws Exception DevREPL.run_tests(
        ReplHelper.PRECOMPILEDATA;
        filter = _ -> error("boom"),
        presentation=DevREPL.RunPresentation(:none))
    rec = first(DevREPL.get_run_history())
    @test rec.status === :errored
    # Left at :running it would be un-prunable, since _prune_history! skips
    # running records — every failure would leak into the history forever.
    @test rec.end_time !== nothing
end

@testitem "a normal run is recorded as completed" setup=[ReplHelper] begin
    DevREPL.run_tests(ReplHelper.PRECOMPILEDATA;
                      presentation=DevREPL.RunPresentation(:none), max_workers=1)
    rec = first(DevREPL.get_run_history())
    @test rec.status === :completed
    @test rec.end_time !== nothing
end

@testitem "errored runs can be pruned" setup=[ReplHelper] begin
    runner = DevREPL.get_runner()
    rec = DevREPL.TestrunRecord("zz", time(), time(), :errored, nothing, "p", nothing)
    lock(runner.lock) do
        pushfirst!(runner.run_history, rec)
    end
    # findlast over a non-:running status must be able to see it.
    @test any(r -> r.status === :errored, DevREPL.get_run_history())
    lock(runner.lock) do
        idx = findlast(r -> r.status != :running, runner.run_history)
        @test idx !== nothing
        deleteat!(runner.run_history, findfirst(r -> r.id == "zz", runner.run_history))
    end
end

@testitem "attach with no background run" setup=[ReplHelper] begin
    ReplHelper.reset_bg_runs!()
    out = ReplHelper.run_command("test attach")
    @test occursin("No background test run to attach", out)
end

@testitem "attach is a known subcommand" begin
    @test "attach" in DevREPL._TEST_SUBCOMMANDS
    m, _ = DevREPL._devrepl_completions("test att")
    @test "attach" in m
end

# Completion used to be re-announced on every command for the rest of the
# session, which detaching makes far more visible.
@testitem "background completion is announced once" setup=[ReplHelper] begin
    bg = ReplHelper.fake_bg_run("7"; finished=true)
    try
        first = ReplHelper.run_command("test status")
        @test occursin("finished", first)
        @test bg.reported
        second = ReplHelper.run_command("test list $(ReplHelper.PRECOMPILEDATA)")
        @test !occursin("finished in", second)
    finally
        ReplHelper.reset_bg_runs!()
    end
end

@testitem "status says nothing about threads or the reactor" setup=[ReplHelper] begin
    ReplHelper.reset_bg_runs!()
    out = ReplHelper.run_command("test status")
    @test occursin("No test runs in progress", out)
    # These were diagnostics nobody asked for at that moment.
    @test !occursin("Threads:", out)
    @test !occursin("Reactor:", out)
end

# The whole point of `test status` is the run in flight, so it must report on
# each run's own context rather than a global "most recent run" pointer.
@testitem "status lists every active run separately" setup=[ReplHelper] begin
    a = ReplHelper.fake_bg_run("11")
    b = ReplHelper.fake_bg_run("12")
    try
        out = ReplHelper.run_command("test status")
        @test occursin("Active runs", out)
        @test occursin("11", out) && occursin("12", out)
        @test occursin("2 runs active", out)
    finally
        ReplHelper.reset_bg_runs!()
    end
end

@testitem "attach and cancel need an id when several runs are active" setup=[ReplHelper] begin
    ReplHelper.fake_bg_run("21")
    ReplHelper.fake_bg_run("22")
    try
        for verb in ("attach", "cancel")
            out = ReplHelper.run_command("test $verb")
            @test occursin("2 runs are active", out)
            @test occursin("test $verb <id>", out)
        end
        # ...and resolve by id, including by prefix.
        @test DevREPL.find_background_run("21").run_id == "21"
        @test DevREPL.find_background_run("99") === nothing
    finally
        ReplHelper.reset_bg_runs!()
    end
end

@testitem "a single active run needs no id" setup=[ReplHelper] begin
    ReplHelper.fake_bg_run("31")
    try
        out = ReplHelper.run_command("test status")
        @test occursin("1 run active", out)
        @test !occursin("Say which", out)
    finally
        ReplHelper.reset_bg_runs!()
    end
end

@testitem "short_id shortens but stays prefix-compatible" begin
    full = "89402ed3-1a5a-4386-8228-29fcdac8913f"
    @test DevREPL.short_id(full) == "89402ed3"
    @test startswith(full, DevREPL.short_id(full))
    @test DevREPL.short_id("abc") == "abc"          # already short
end

@testitem "elapsed formatting" begin
    @test DevREPL._format_elapsed(4.24) == "4.2s"
    @test DevREPL._format_elapsed(72) == "1m12s"
    @test DevREPL._format_elapsed(3 * 3600 + 5 * 60) == "3h05m"
end

# max_workers is per-run and the controller has no global cap, so without a
# budget every concurrent run claims the full allowance.
@testitem "worker budget is shared across runs" begin
    DevREPL._release_workers!("w1")
    try
        @test DevREPL._worker_budget(nothing) == DevREPL.default_max_workers()
        DevREPL._note_workers!("w1", DevREPL.default_max_workers())
        # Nothing left, but a run still needs at least one worker to progress.
        @test DevREPL._worker_budget(nothing) == 1
        # An explicit --workers=N is the user overriding the budget.
        @test DevREPL._worker_budget(4) == 4
    finally
        DevREPL._release_workers!("w1")
    end
    @test DevREPL._worker_budget(nothing) == DevREPL.default_max_workers()
end
