# TestItemControllers.jl

TestItemControllers.jl is the orchestration engine behind the [Julia test items](https://julia-testitems.github.io/) ecosystem.
It manages the lifecycle of Julia child processes, schedules `@testitem` work units across multiple environments, and reports results back to a host (e.g. VS Code, a CLI, or a REPL dashboard) via callbacks or a JSONRPC protocol.

## Key features

- **Multi-environment test runs** — run the same test items against different Julia configurations (versions, thread counts, environment variables, coverage/debug modes) in a single invocation.
- **Process pooling** — idle Julia processes are kept in a pool and reused across test runs, with automatic Revise-based hot-reloading when source code changes.
- **Event-driven reactor** — all state mutations flow through a single-threaded reactor loop, eliminating concurrency bugs while allowing async I/O.
- **Three finite state machines** — controller, process, and test-run phases are modelled as explicit FSMs with guarded transitions.
- **Cancellation and timeouts** — per-item timeouts and per-run cancellation tokens propagate cleanly through the process pool.
- **Coverage collection** — optional per-file line-level coverage aggregated across processes.
- **Debug support** — processes expose a named pipe for attaching a debug adapter.

## Usage modes

TestItemControllers.jl can be consumed in two ways:

1. **Native Julia API** — construct a [`TestItemController`](@ref) with a [`ControllerCallbacks`](@ref) struct, then call [`execute_testrun`](@ref) directly. This is the approach used by the CLI and REPL integrations.

2. **JSONRPC API** — construct a [`JSONRPCTestItemController`](@ref) over a pair of I/O streams. The host sends `createTestRun` requests and receives progress notifications over the wire. This is the approach used by the VS Code extension.

## Documentation sections

| Section | Contents |
|:--------|:---------|
| [Julia API](@ref) | Exported types, callbacks, and functions for direct Julia usage |
| [JSONRPC API](@ref) | Wire protocol: requests, notifications, and message formats |
| [Internals](@ref) | Architecture deep-dive: reactor, FSMs, process management, protocols |
