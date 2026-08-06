# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - Unreleased

### Added

- Support for Julia 1.13 testset handling ([c0dc08fe](https://github.com/julia-vscode/TestItemControllers.jl/commit/c0dc08fe))
- Improved error propagation from test processes ([f8c59681](https://github.com/julia-vscode/TestItemControllers.jl/commit/f8c59681))
- Improved error display for test items ([5abad6c2](https://github.com/julia-vscode/TestItemControllers.jl/commit/5abad6c2))
- Improved logging ([7e81011d](https://github.com/julia-vscode/TestItemControllers.jl/commit/7e81011d))
- Improved cancellation handling ([9e7e0c05](https://github.com/julia-vscode/TestItemControllers.jl/commit/9e7e0c05), [ac4e2201](https://github.com/julia-vscode/TestItemControllers.jl/commit/ac4e2201))
- Added `.gitignore` ([c7545dd0](https://github.com/julia-vscode/TestItemControllers.jl/commit/c7545dd0))
- Vendored Preferences package ([f050d17e](https://github.com/julia-vscode/TestItemControllers.jl/commit/f050d17e))

### Changed

- Load setup modules via `using` by default ([2b187ad1](https://github.com/julia-vscode/TestItemControllers.jl/commit/2b187ad1))
- Updated LICENSE ([2008be43](https://github.com/julia-vscode/TestItemControllers.jl/commit/2008be43))

### Fixed

- A test run could report itself complete while one of its test items was still shown as running, most often on large runs with several worker processes. Work stealing is speculative — the thief is handed the item before the victim confirms it gave it up, and a victim already executing that item runs it to completion regardless — so both processes reported on the same item. The controller now tracks which process actually owns each item and discards everything a non-owning process reports, so each item produces exactly one terminal callback and its status never moves backwards. Previously a late duplicate `started` reset an already-resolved item to running and the duplicate's own result was silently dropped, leaving nothing to move it back.
- `duration` in the test item callbacks and the JSON-RPC notifications was documented as seconds but has always been milliseconds. The documentation now says milliseconds; no reported value changed.
- Preferences set in the user's environment (`LocalPreferences.toml`, or a `[preferences]` section in the project file) are now honoured inside the test process, including while it precompiles. `TestEnv.activate` makes a temporary directory of its own the active project and carries only the project and the manifest over to it, so preferences placed next to the activated project were dropped before anything was compiled — most visibly making PrecompileTools' `precompile_workload = false` escape hatch have no effect on a test run. They now travel in a dedicated, dependency-less environment directory appended to `LOAD_PATH`, which is where Julia resolves preferences from and which it passes on to every precompilation subprocess. ([#28](https://github.com/julia-testitems/TestItemControllers.jl/issues/28))
- Test runs no longer write into the user's environment. Previously `TestEnv.activate` ran `Pkg.instantiate` on the activated project, which resolved a `Manifest.toml` into the package or project folder whenever one was missing. The environment is now mirrored into a temporary directory (with all recorded paths made absolute) and that copy is activated instead, so the user's working tree is only ever read. Two consequences: an existing `Manifest.toml` is now honoured even when no separate project is configured, where before the run re-resolved from scratch, and `Base.active_project()` inside a test item no longer points at the user's folder.
- Fixed process termination handling ([b1904e84](https://github.com/julia-vscode/TestItemControllers.jl/commit/b1904e84))
- Fixed resource leak in test processes ([163cd85c](https://github.com/julia-vscode/TestItemControllers.jl/commit/163cd85c))
- Fixed various race conditions ([08489edf](https://github.com/julia-vscode/TestItemControllers.jl/commit/08489edf), [735bf2f3](https://github.com/julia-vscode/TestItemControllers.jl/commit/735bf2f3), [d2fa212c](https://github.com/julia-vscode/TestItemControllers.jl/commit/d2fa212c), [5fd4c883](https://github.com/julia-vscode/TestItemControllers.jl/commit/5fd4c883))
- Fixed cancellation bugs ([2c7c630f](https://github.com/julia-vscode/TestItemControllers.jl/commit/2c7c630f))
- Fixed state transition bugs ([cbfd87e3](https://github.com/julia-vscode/TestItemControllers.jl/commit/cbfd87e3), [9faff42f](https://github.com/julia-vscode/TestItemControllers.jl/commit/9faff42f))
- Fixed import issues ([05bef6c7](https://github.com/julia-vscode/TestItemControllers.jl/commit/05bef6c7))
- Fixed reference to non-existent params ([45b7fcb8](https://github.com/julia-vscode/TestItemControllers.jl/commit/45b7fcb8))
- Improved robustness of test process management ([9d82f4ce](https://github.com/julia-vscode/TestItemControllers.jl/commit/9d82f4ce))
- Various minor bug fixes and typo corrections

### Updated

- Updated vendored packages: CancellationTokens, JSONRPC, JuliaInterpreter, CodeTracking, LoweredCodeUtils, Revise, TestEnv, CoverageTools, Preferences
- Updated test server environments ([b96e6a6c](https://github.com/julia-vscode/TestItemControllers.jl/commit/b96e6a6c), [8034d88a](https://github.com/julia-vscode/TestItemControllers.jl/commit/8034d88a))

## [1.0.0] - 2025-07-17

Initial release.

[2.0.0]: https://github.com/julia-vscode/TestItemControllers.jl/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/julia-vscode/TestItemControllers.jl/releases/tag/v1.0.0
