"""
    ControllerPhase

States for the controller-level FSM.
- `ControllerRunning`: Normal operation, accepts new test runs
- `ControllerShuttingDown`: Rejects new test runs, cancels active runs, drains process pool
- `ControllerStopped`: Reactor loop breaks
"""
@enum ControllerPhase begin
    ControllerRunning
    ControllerShuttingDown
    ControllerStopped
end

"""
    TestProcessPhase

States for the per-process FSM. `ProcessDead` is reachable from any state.
"""
@enum TestProcessPhase begin
    ProcessCreated
    ProcessIdle
    ProcessReviseOrStart
    ProcessRevising
    ProcessStarting
    ProcessWaitingForPrecompile
    ProcessActivatingEnv
    ProcessConfiguringTestRun
    ProcessReadyToRun
    ProcessRunning
    ProcessDead
end

"""
    TestRunPhase

States for the per-test-run FSM.
"""
@enum TestRunPhase begin
    TestRunCreated
    TestRunWaitingForProcs
    TestRunProcsAcquired
    TestRunRunning
    TestRunCancelled
    TestRunCompleted
end

"""
    FSM{S}

Simple finite state machine parameterized on state enum type `S`.
Validates transitions against an allowed-transition table and logs changes.
"""
mutable struct FSM{S}
    current::S
    transitions::Dict{S,Set{S}}
    id::String
end

"""Return the current state of the FSM."""
state(fsm::FSM) = fsm.current

"""
    transition!(fsm, new_state; reason=nothing)

Transition the FSM to `new_state`. Raises an error if the transition is not allowed.
"""
function transition!(fsm::FSM{S}, new_state::S; reason=nothing) where S
    allowed = get(fsm.transitions, fsm.current, Set{S}())
    if new_state ∉ allowed
        error("Invalid FSM transition for '$(fsm.id)': $(fsm.current) → $(new_state)" *
              (reason !== nothing ? " (reason: $reason)" : ""))
    end
    old_state = fsm.current
    fsm.current = new_state
    @debug "FSM transition" id=fsm.id from=old_state to=new_state reason
    return new_state
end

"""Create a controller-phase FSM starting in `ControllerRunning`."""
function controller_fsm(id::String)
    transitions = Dict{ControllerPhase,Set{ControllerPhase}}(
        ControllerRunning      => Set([ControllerShuttingDown]),
        ControllerShuttingDown => Set([ControllerStopped]),
    )
    return FSM(ControllerRunning, transitions, id)
end

"""Create a test-process-phase FSM starting in `ProcessCreated`."""
function testprocess_fsm(id::String)
    dead_set = Set([ProcessDead])

    transitions = Dict{TestProcessPhase,Set{TestProcessPhase}}()
    # ANY → Dead (except Dead itself)
    for phase in instances(TestProcessPhase)
        if phase != ProcessDead
            transitions[phase] = copy(dead_set)
        end
    end
    # Specific transitions (merged with Dead)
    union!(transitions[ProcessCreated],             Set([ProcessIdle, ProcessReviseOrStart, ProcessStarting]))
    union!(transitions[ProcessIdle],                Set([ProcessReviseOrStart]))
    union!(transitions[ProcessReviseOrStart],       Set([ProcessRevising, ProcessStarting]))
    union!(transitions[ProcessRevising],            Set([ProcessActivatingEnv, ProcessConfiguringTestRun]))
    union!(transitions[ProcessStarting],            Set([ProcessWaitingForPrecompile, ProcessActivatingEnv, ProcessIdle]))
    union!(transitions[ProcessWaitingForPrecompile],Set([ProcessActivatingEnv]))
    union!(transitions[ProcessActivatingEnv],       Set([ProcessConfiguringTestRun]))
    union!(transitions[ProcessConfiguringTestRun],  Set([ProcessReadyToRun]))
    union!(transitions[ProcessReadyToRun],          Set([ProcessRunning]))
    union!(transitions[ProcessRunning],             Set([ProcessIdle]))

    # Allow return to idle (→ ProcessIdle) from intermediate setup states
    # so that cancellation can cleanly return processes to the pool.
    for phase in (ProcessReviseOrStart, ProcessRevising, ProcessWaitingForPrecompile,
                  ProcessActivatingEnv, ProcessConfiguringTestRun, ProcessReadyToRun)
        push!(transitions[phase], ProcessIdle)
    end

    return FSM(ProcessCreated, transitions, id)
end

"""Create a test-run-phase FSM starting in `TestRunCreated`."""
function testrun_fsm(id::String)
    transitions = Dict{TestRunPhase,Set{TestRunPhase}}(
        TestRunCreated         => Set([TestRunWaitingForProcs, TestRunCancelled]),
        TestRunWaitingForProcs => Set([TestRunProcsAcquired, TestRunCancelled]),
        TestRunProcsAcquired   => Set([TestRunRunning, TestRunCancelled, TestRunCompleted]),
        TestRunRunning         => Set([TestRunCancelled, TestRunCompleted]),
    )
    return FSM(TestRunCreated, transitions, id)
end
