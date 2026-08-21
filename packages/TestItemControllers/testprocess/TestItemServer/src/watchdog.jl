# In-process hang diagnostics.
#
# The controller sends a `timeoutMs` deadline with every test item. We arm a watchdog just
# short of it, so that an item which is about to be killed for running too long leaves a
# stack behind instead of a single "timed out" line. Three constraints shape this:
#
#   * The watchdog must not depend on libuv. When a test item wedges the main thread no
#     thread services the event loop any more, so `sleep`, `Timer` and socket writes never
#     complete. The watchdog therefore paces itself with `Libc.systemsleep` (a plain OS
#     sleep) and writes to a file through `IOStream`, which is a blocking `write(2)` and
#     needs no running loop.
#   * The watchdog must not share a thread with the test item. The launch reserves two
#     interactive threads on Julia >= 1.9 (see `src/testprocess.jl`): the main task — and
#     therefore the runner loop and every test item — sits on the first, and this watchdog
#     runs on the second.
#   * It cannot help against an item that neither allocates nor yields. Such an item never
#     reaches a GC safepoint, so the watchdog's first allocation blocks behind a GC that
#     can never start. The controller's own timeout remains the backstop for that case.
#
# The dump goes to a file of its own rather than to stderr: a `Profile.print` is far larger
# than the 4 KiB POSIX pipes guarantee to write atomically (and Windows named pipes
# guarantee nothing), so sharing the captured-output stream with a test item that is still
# printing would shred both. One writer, one file, no framing needed. The controller reads
# the file when its own timeout fires and attributes the contents to whichever item the
# process was running. It is written section by section (see `_write_dump`), so a dump that
# is slow to build on a loaded machine still leaves its first sections behind.

# Set by the controller on the test process launch; absent means diagnostics are disabled.
const DIAGNOSTICS_FILE_ENV_VAR = "JULIA_TESTITEMSERVER_DIAGNOSTICS_FILE"

# Fire this far ahead of the controller's deadline. The real margin comes from the grace
# period the controller adds before it kills the process; this only avoids racing it.
const WATCHDOG_LEAD_MS = 250.0

# Granularity of the watchdog's own sleep, and how long we let the sampler run.
const WATCHDOG_POLL_SECONDS = 0.05
const WATCHDOG_PROFILE_SECONDS = 1.0

const WATCHDOG_FILE = Ref{Union{Nothing,String}}(nothing)
# `time()` at which to dump, or 0.0 when disarmed. Written by the runner loop, read by the
# watchdog thread; a torn read would at worst dump early or late.
const WATCHDOG_DEADLINE = Ref{Float64}(0.0)
const WATCHDOG_ITEM_ID = Ref{String}("")
const WATCHDOG_ITEM_TIMEOUT_MS = Ref{Float64}(0.0)
const WATCHDOG_RUNNING = Ref{Bool}(false)
# Asks the watchdog thread to leave its loop. Set before a deliberate `exit`, so the runtime
# is not torn down while another thread is still running Julia code — see `stop_watchdog!`.
const WATCHDOG_STOP = Ref{Bool}(false)

function _init_watchdog_globals!()
    WATCHDOG_FILE[] = nothing
    WATCHDOG_DEADLINE[] = 0.0
    WATCHDOG_ITEM_ID[] = ""
    WATCHDOG_ITEM_TIMEOUT_MS[] = 0.0
    WATCHDOG_RUNNING[] = false
    WATCHDOG_STOP[] = false
    return nothing
end

function _write_diagnostics(text::AbstractString)
    file = WATCHDOG_FILE[]
    file === nothing && return nothing
    try
        open(file, "a") do io
            write(io, text)
            flush(io)
        end
    catch err
        # There is nothing to fall back to: this path exists precisely because the normal
        # channels may be unusable.
    end
    return nothing
end

# `Profile` is a declared dependency of this package, which means it also has to be in the
# manifest of every pinned environment the test process runs in (`testprocess/environments/v*`
# — regenerate them with `scripts/update_app_environments.jl` and never let one drift). The
# alternative, loading it at runtime with `Base.require(Main, :Profile)`, was what this used to
# do, on the grounds that the pinned environments did not list it. A by-name lookup goes through
# the load path and only reaches a stdlib while `@stdlib` is on it, so under any host that pins
# `JULIA_LOAD_PATH` — `Pkg.test`, i.e. our own CI — it failed and every hang dump silently lost
# its profile. Resolving through the manifest does not care about the load path, and being
# imported at precompile time it also keeps the sampler out of the world-age trouble a runtime
# `require` caused for the watchdog task.
function _capture_profile()
    Profile.init(n = 10^7, delay = 0.005)
    Profile.clear()
    Profile.start_timer()
    try
        t0 = time()
        while time() - t0 < WATCHDOG_PROFILE_SECONDS
            Libc.systemsleep(WATCHDOG_POLL_SECONDS)
            GC.safepoint()  # same reason as in `_watchdog_loop`
        end
    finally
        Profile.stop_timer()
    end

    io = IOContext(IOBuffer(), :displaysize => (24, 200))
    # `groupby` only exists from Julia 1.8 on, and `print` warns about empty groups and
    # about Windows sampling only the main thread — neither belongs in a test item's output.
    Logging.with_logger(Logging.NullLogger()) do
        try
            Profile.print(io; groupby = :thread, C = false, maxdepth = 40)
        catch err
            Profile.print(io; C = false, maxdepth = 40)
        end
    end
    return String(take!(io.io))
end

# A CPU profile only shows code that is *running*. A wedged reactor or a task blocked in a
# `wait` never appears in it, so we also dump every live task's backtrace. The runtime
# exports `jl_print_task_backtraces` for exactly this (it is what SIGINFO/SIGUSR1 use), but
# it prints straight to fd 2 with `jl_safe_printf`, so we point fd 2 at a scratch file for
# the duration. Julia < 1.10 does not have the symbol; the ccall then throws and we say so.
function _capture_task_backtraces()
    file = WATCHDOG_FILE[]
    file === nothing && return ""
    scratch = file * ".tasks"
    text = ""
    saved_stderr = Base.Libc.dup(RawFD(2))
    try
        open(scratch, "w") do io
            flush(io)
            Base.Libc.dup(RawFD(fd(io)), RawFD(2))
            try
                ccall(:jl_print_task_backtraces, Cvoid, (Cint,), 0)
            finally
                Base.Libc.dup(saved_stderr, RawFD(2))
            end
        end
        text = read(scratch, String)
    finally
        # `dup` handed us a fresh descriptor; close it directly, no libuv involved. (`RawFD`
        # converts to `Cint` in the ccall; it has no field to reach into on newer Julia.)
        @static if Sys.iswindows()
            ccall(:_close, Cint, (Cint,), saved_stderr)
        else
            ccall(:close, Cint, (Cint,), saved_stderr)
        end
        try rm(scratch; force = true) catch end
    end
    return text
end

function _memory_summary()
    return try
        free = Sys.free_memory() / 2^30
        total = Sys.total_memory() / 2^30
        live = Base.gc_live_bytes() / 2^30
        string(round(live, digits = 2), " GiB live, ", round(free, digits = 2), " of ",
            round(total, digits = 2), " GiB system memory free")
    catch err
        "unavailable"
    end
end

function _thread_summary()
    return @static if VERSION >= v"1.9"
        string(Threads.nthreads(:default), " default + ", Threads.nthreads(:interactive), " interactive")
    else
        string(Threads.nthreads())
    end
end

const DUMP_RULE = "─"^78

function _dump_header(testitem_id::AbstractString, timeout_ms::Float64)
    io = IOBuffer()
    println(io)
    println(io, DUMP_RULE)
    println(io, "Hang diagnostics for test item '", testitem_id, "'")
    println(io, "Captured by the test process watchdog because the item was still running ",
        round(timeout_ms / 1000, digits = 1), "s into its timeout.")
    println(io, "Julia ", VERSION, " on ", Sys.MACHINE, ", pid ", getpid(), ", threads: ", _thread_summary())
    println(io, "Memory: ", _memory_summary())
    println(io, DUMP_RULE)
    return String(take!(io))
end

function _dump_task_backtraces()
    io = IOBuffer()
    println(io, "Task backtraces")
    try
        tasks_text = _capture_task_backtraces()
        if isempty(strip(tasks_text))
            println(io, "No task backtraces: the runtime produced no output.")
        else
            print(io, tasks_text)
            endswith(tasks_text, "
") || println(io)
        end
    catch err
        println(io, "No task backtraces: capturing them failed with ", sprint(showerror, err))
    end
    println(io, DUMP_RULE)
    return String(take!(io))
end

function _dump_profile()
    io = IOBuffer()
    println(io, "CPU profile")
    try
        profile_text = _capture_profile()
        if isempty(strip(profile_text))
            println(io, "No CPU profile: the sampler collected no snapshots.")
        else
            print(io, profile_text)
        end
    catch err
        println(io, "No CPU profile: capturing one failed with ", sprint(showerror, err))
    end
    println(io, DUMP_RULE)
    return String(take!(io))
end

# The dump is written in sections, each appended to the file the moment it is ready, rather
# than assembled and written once at the end. The controller only waits a fixed grace period
# past the item's timeout before it kills the process and reads the file, and the profile
# alone spends a second sampling and then pays for a cold `Profile.print`; on a slow CI
# runner the full dump overran that window and *nothing* reached the file. Cheapest and most
# useful first: the header is instant, task backtraces are what locate a blocked task, and
# the profile — which only ever shows running code — comes last.
function _write_dump(testitem_id::AbstractString, timeout_ms::Float64)
    _write_diagnostics(_dump_header(testitem_id, timeout_ms))
    _write_diagnostics(_dump_task_backtraces())
    _write_diagnostics(_dump_profile())
    return nothing
end

function _watchdog_loop()
    while !WATCHDOG_STOP[]
        Libc.systemsleep(WATCHDOG_POLL_SECONDS)

        # Mandatory. This loop neither allocates nor yields, and `Libc.systemsleep` is a
        # plain `ccall`, so without an explicit safepoint the thread never becomes
        # collectable — and `GC.gc(true)` between test items, which stops the world, blocks
        # here forever. Verified: removing this deadlocks the test process on its first
        # inter-item collection, which is why the watchdog cannot use a yield-free loop
        # without one.
        GC.safepoint()

        deadline = WATCHDOG_DEADLINE[]
        (deadline > 0.0 && time() >= deadline) || continue

        # Disarm before dumping: one dump per armed item, however long the dump takes.
        WATCHDOG_DEADLINE[] = 0.0
        testitem_id = WATCHDOG_ITEM_ID[]
        timeout_ms = WATCHDOG_ITEM_TIMEOUT_MS[]

        try
            _write_dump(testitem_id, timeout_ms)
        catch err
            # Deliberately swallowed — a failing watchdog must not take the process down.
        end
    end
    # Lets `stop_watchdog!` see that this thread is out of Julia code before the caller exits.
    WATCHDOG_RUNNING[] = false
    return nothing
end

# Nothing waits on the watchdog task, so an exception anywhere outside `_write_dump`'s own
# `try` would end it silently while `WATCHDOG_RUNNING[]` still claimed it was alive — and
# `stop_watchdog!` would then wait for a thread that is already gone. Report it and leave the
# flag telling the truth.
function _guarded_watchdog_loop()
    try
        _watchdog_loop()
    catch err
        WATCHDOG_RUNNING[] = false
        report_error(err, catch_backtrace())
    end
    return nothing
end

"""
    start_watchdog!()

Load the diagnostics file path and start the watchdog thread.
Returns `true` when the watchdog is running. Called once, at test process startup, while
the process is still healthy.
"""
function start_watchdog!()
    _init_watchdog_globals!()

    file = get(ENV, DIAGNOSTICS_FILE_ENV_VAR, "")
    isempty(file) && return false
    WATCHDOG_FILE[] = file

    @static if VERSION >= v"1.9"
        # Preferred: our own interactive thread, which the default pool cannot starve.
        if Threads.nthreads(:interactive) >= 2
            Threads.@spawn :interactive _guarded_watchdog_loop()
            WATCHDOG_RUNNING[] = true
            return true
        end
    end

    @static if VERSION >= v"1.3"
        # Fallback: any spare thread. Weaker, because a test item that saturates the
        # default pool can keep the watchdog off the CPU.
        if Threads.nthreads() >= 2
            Threads.@spawn _guarded_watchdog_loop()
            WATCHDOG_RUNNING[] = true
            return true
        end
    end

    @debug "No spare thread for the hang watchdog; timeouts will not produce a diagnostic dump"
    return false
end

"""
    arm_watchdog!(testitem_id, timeout_ms)

Schedule a diagnostic dump shortly before `timeout_ms` from now. A `missing` timeout — the
controller did not set one for this item — disarms instead.
"""
function arm_watchdog!(testitem_id::AbstractString, timeout_ms::Union{Missing,Float64})
    if !WATCHDOG_RUNNING[] || timeout_ms === missing || timeout_ms <= 0
        WATCHDOG_DEADLINE[] = 0.0
        return nothing
    end

    WATCHDOG_ITEM_ID[] = String(testitem_id)
    WATCHDOG_ITEM_TIMEOUT_MS[] = timeout_ms
    WATCHDOG_DEADLINE[] = time() + max(0.0, timeout_ms - WATCHDOG_LEAD_MS) / 1000
    return nothing
end

"""
    disarm_watchdog!()

Cancel any pending dump. Cheap enough to call unconditionally after every test item.
"""
function disarm_watchdog!()
    WATCHDOG_DEADLINE[] = 0.0
    return nothing
end

"""
    stop_watchdog!()

Ask the watchdog thread to leave its loop and wait briefly for it to do so.

Call this before any deliberate `exit` from the runner loop. `exit` tears the runtime down
from the calling thread, and if the watchdog is still executing Julia code — a safepoint, an
allocation, a JIT-compiled frame — that teardown races it. On Windows that surfaced as an
`EXCEPTION_ACCESS_VIOLATION` inside the JIT; elsewhere it showed up as the process failing
to exit at all, which stalled controller shutdown.
"""
function stop_watchdog!()
    WATCHDOG_DEADLINE[] = 0.0
    WATCHDOG_STOP[] = true
    WATCHDOG_RUNNING[] || return nothing

    # One poll interval is enough for the loop to observe the flag; the small margin covers
    # a thread that was mid-sleep when it was set.
    deadline = time() + 10 * WATCHDOG_POLL_SECONDS
    while WATCHDOG_RUNNING[] && time() < deadline
        Libc.systemsleep(WATCHDOG_POLL_SECONDS)
    end
    return nothing
end
