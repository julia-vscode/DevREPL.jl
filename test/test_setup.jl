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
end
