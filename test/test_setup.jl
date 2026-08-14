@testmodule ReplHelper begin
    using DevREPL

    # Run DevREPL.repl_parser with captured stdout, returning the output.
    function run_command(input::String)
        out_path, out_io = mktemp()
        try
            redirect_stdio(() -> DevREPL.repl_parser(input); stdout=out_io, stderr=out_io)
        finally
            close(out_io)
        end
        return read(out_path, String)
    end

    const PRECOMPILEDATA = normpath(joinpath(dirname(pathof(DevREPL)), "..", "precompiledata"))

    using TestItemControllers.CancellationTokens: CancellationTokenSource

    "Forget every background run — test items share a process, so state leaks between them."
    function reset_bg_runs!()
        lock(DevREPL._bg_runs_lock) do
            empty!(DevREPL._bg_runs)
        end
    end

    """
        fake_bg_run(id; finished=false)

    Register a `BackgroundRun` with no real test run behind it, so the commands
    that report on background runs can be exercised without spawning processes.
    """
    function fake_bg_run(id::String; finished::Bool=false)
        task = Threads.@spawn (finished || sleep(120); :done)
        finished && wait(task)
        bg = DevREPL.BackgroundRun(id, task, CancellationTokenSource(),
                                   nothing, nothing, time(), false)
        if finished
            bg.result = DevREPL.TestrunResult(
                DevREPL.TestrunResultDefinitionError[], DevREPL.TestrunResultTestitem[],
                Dict{String,String}())
        end
        lock(DevREPL._bg_runs_lock) do
            DevREPL._bg_runs[id] = bg
        end
        return bg
    end
end
