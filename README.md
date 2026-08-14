# DevREPL.jl

> **Prerelease:** DevREPL.jl is currently a prerelease package. The API and behavior may change before the first stable release.

DevREPL.jl provides an interactive REPL mode for running [test items](https://github.com/julia-testitems/TestItems.jl) directly from the Julia terminal. Press `)` at the `julia>` prompt to enter `dev>` mode and run, filter, and inspect tests without leaving the REPL.

## Documentation

Full documentation is available at **https://julia-testitems.org/guide/repl**.

## Quick Start

Install into your global environment:

```julia
using Pkg
Pkg.add(url="https://github.com/julia-vscode/DevREPL.jl")
```

Then load it and press `)` to enter the DevREPL mode:

```julia
using DevREPL
```

```
julia> )
dev> test run
```

## Commands

Every test command takes a subcommand; `t` is a shorthand for `test`.

| Command | Description |
| --- | --- |
| `test run [path\|name]` | Run test items (Esc cancels, `b` backgrounds) |
| `test run --bg` | Run test items in the background (several may run at once) |
| `test attach [id]` | Watch a background run as if it had been run in the foreground |
| `test pick [query] [path]` | Fuzzy-pick test items to run interactively |
| `test failed` | Rerun only the failing items of the last run |
| `test repeat` | Repeat the last test run |
| `test list [path]` | List discovered test items (alias: `ls`) |
| `test results [id]` | Show results (alias: `res`) |
| `test failures` | Browse failures of the last run, jumping to your editor |
| `test history [--active]` | List all test runs |
| `test status` | Show runs in progress (alias: `st`) |
| `test cancel [id]` | Cancel a run (id required when several are active) |
| `test procs` | Show active test processes (alias: `ps`) |
| `test kill [id]` | Kill all or a specific test process |
| `test log <id>` | Show the output log for a test process |
| `lint [path]` | Lint a folder (respects `JuliaLint.toml`) |
| `format [path]` | Format a file or folder in place |

Run flags: `--name=`, `--tags=`, `--workers=`, `--timeout=`, `--coverage`, `--bg`, and `+channel` for a Juliaup channel.

## License

MIT
