@testitem "controller_fsm valid transitions" begin
    using TestItemControllers: controller_fsm, state, transition!,
        ControllerRunning, ControllerShuttingDown, ControllerStopped

    fsm = controller_fsm("test-ctrl")
    @test state(fsm) == ControllerRunning

    transition!(fsm, ControllerShuttingDown)
    @test state(fsm) == ControllerShuttingDown

    transition!(fsm, ControllerStopped)
    @test state(fsm) == ControllerStopped
end

@testitem "controller_fsm invalid transition" begin
    using TestItemControllers: controller_fsm, state, transition!,
        ControllerRunning, ControllerStopped

    fsm = controller_fsm("test-ctrl")
    @test state(fsm) == ControllerRunning

    # Cannot skip directly to Stopped
    @test_throws ErrorException transition!(fsm, ControllerStopped)
    # State should remain unchanged after failed transition
    @test state(fsm) == ControllerRunning
end

@testitem "testprocess_fsm valid transitions" begin
    using TestItemControllers: testprocess_fsm, state, transition!,
        ProcessCreated, ProcessIdle, ProcessReviseOrStart, ProcessRevising,
        ProcessStarting, ProcessWaitingForPrecompile, ProcessActivatingEnv,
        ProcessConfiguringTestRun, ProcessReadyToRun, ProcessRunning

    # Path: Created → Idle → ReviseOrStart → Revising → ActivatingEnv → ConfiguringTestRun → ReadyToRun → Running → Idle
    fsm = testprocess_fsm("proc-1")
    @test state(fsm) == ProcessCreated

    transition!(fsm, ProcessIdle)
    @test state(fsm) == ProcessIdle

    transition!(fsm, ProcessReviseOrStart)
    @test state(fsm) == ProcessReviseOrStart

    transition!(fsm, ProcessRevising)
    @test state(fsm) == ProcessRevising

    transition!(fsm, ProcessActivatingEnv)
    @test state(fsm) == ProcessActivatingEnv

    transition!(fsm, ProcessConfiguringTestRun)
    @test state(fsm) == ProcessConfiguringTestRun

    transition!(fsm, ProcessReadyToRun)
    @test state(fsm) == ProcessReadyToRun

    transition!(fsm, ProcessRunning)
    @test state(fsm) == ProcessRunning

    transition!(fsm, ProcessIdle)
    @test state(fsm) == ProcessIdle

    # Path through Starting: ReviseOrStart → Starting → ActivatingEnv
    fsm2 = testprocess_fsm("proc-2")
    transition!(fsm2, ProcessReviseOrStart)
    transition!(fsm2, ProcessStarting)
    @test state(fsm2) == ProcessStarting

    transition!(fsm2, ProcessActivatingEnv)
    @test state(fsm2) == ProcessActivatingEnv

    # Path: Starting → WaitingForPrecompile → ActivatingEnv
    fsm3 = testprocess_fsm("proc-3")
    transition!(fsm3, ProcessReviseOrStart)
    transition!(fsm3, ProcessStarting)
    transition!(fsm3, ProcessWaitingForPrecompile)
    @test state(fsm3) == ProcessWaitingForPrecompile

    transition!(fsm3, ProcessActivatingEnv)
    @test state(fsm3) == ProcessActivatingEnv

    # Path: Starting → Idle (no testrun)
    fsm4 = testprocess_fsm("proc-4")
    transition!(fsm4, ProcessReviseOrStart)
    transition!(fsm4, ProcessStarting)
    transition!(fsm4, ProcessIdle)
    @test state(fsm4) == ProcessIdle

    # Path: Created → ReviseOrStart (direct)
    fsm5 = testprocess_fsm("proc-5")
    transition!(fsm5, ProcessReviseOrStart)
    @test state(fsm5) == ProcessReviseOrStart

end

@testitem "testprocess_fsm ProcessDead from every state" begin
    using TestItemControllers: testprocess_fsm, state, transition!,
        ProcessCreated, ProcessIdle, ProcessReviseOrStart, ProcessRevising,
        ProcessStarting, ProcessWaitingForPrecompile, ProcessActivatingEnv,
        ProcessConfiguringTestRun, ProcessReadyToRun, ProcessRunning, ProcessDead

    # Every state except ProcessDead should be able to transition to ProcessDead
    all_phases = [ProcessCreated, ProcessIdle, ProcessReviseOrStart, ProcessRevising,
                  ProcessStarting, ProcessWaitingForPrecompile, ProcessActivatingEnv,
                  ProcessConfiguringTestRun, ProcessReadyToRun, ProcessRunning]

    for phase in all_phases
        fsm = testprocess_fsm("proc-dead-test")
        # Get to the target state
        if phase == ProcessCreated
            # Already there
        elseif phase == ProcessIdle
            transition!(fsm, ProcessIdle)
        elseif phase == ProcessReviseOrStart
            transition!(fsm, ProcessReviseOrStart)
        elseif phase == ProcessRevising
            transition!(fsm, ProcessReviseOrStart)
            transition!(fsm, ProcessRevising)
        elseif phase == ProcessStarting
            transition!(fsm, ProcessStarting)
        elseif phase == ProcessWaitingForPrecompile
            transition!(fsm, ProcessStarting)
            transition!(fsm, ProcessWaitingForPrecompile)
        elseif phase == ProcessActivatingEnv
            transition!(fsm, ProcessStarting)
            transition!(fsm, ProcessActivatingEnv)
        elseif phase == ProcessConfiguringTestRun
            transition!(fsm, ProcessStarting)
            transition!(fsm, ProcessActivatingEnv)
            transition!(fsm, ProcessConfiguringTestRun)
        elseif phase == ProcessReadyToRun
            transition!(fsm, ProcessStarting)
            transition!(fsm, ProcessActivatingEnv)
            transition!(fsm, ProcessConfiguringTestRun)
            transition!(fsm, ProcessReadyToRun)
        elseif phase == ProcessRunning
            transition!(fsm, ProcessStarting)
            transition!(fsm, ProcessActivatingEnv)
            transition!(fsm, ProcessConfiguringTestRun)
            transition!(fsm, ProcessReadyToRun)
            transition!(fsm, ProcessRunning)
        end

        @test state(fsm) == phase
        transition!(fsm, ProcessDead)
        @test state(fsm) == ProcessDead
    end
end

@testitem "testprocess_fsm ProcessStarting only from launch states" begin
    using TestItemControllers: testprocess_fsm, state, transition!,
        ProcessCreated, ProcessIdle, ProcessReviseOrStart, ProcessRevising, ProcessStarting,
        ProcessWaitingForPrecompile, ProcessActivatingEnv, ProcessConfiguringTestRun,
        ProcessReadyToRun, ProcessRunning

    fsm = testprocess_fsm("proc-starting-created")
    transition!(fsm, ProcessStarting)
    @test state(fsm) == ProcessStarting

    fsm2 = testprocess_fsm("proc-starting-reviseorstart")
    transition!(fsm2, ProcessReviseOrStart)
    transition!(fsm2, ProcessStarting)
    @test state(fsm2) == ProcessStarting

    invalid_states = [
        ProcessIdle,
        ProcessRevising,
        ProcessWaitingForPrecompile,
        ProcessActivatingEnv,
        ProcessConfiguringTestRun,
        ProcessReadyToRun,
        ProcessRunning,
    ]

    for phase in invalid_states
        fsm_invalid = testprocess_fsm("proc-starting-invalid")
        if phase == ProcessIdle
            transition!(fsm_invalid, ProcessIdle)
        elseif phase == ProcessRevising
            transition!(fsm_invalid, ProcessReviseOrStart)
            transition!(fsm_invalid, ProcessRevising)
        elseif phase == ProcessWaitingForPrecompile
            transition!(fsm_invalid, ProcessStarting)
            transition!(fsm_invalid, ProcessWaitingForPrecompile)
        elseif phase == ProcessActivatingEnv
            transition!(fsm_invalid, ProcessStarting)
            transition!(fsm_invalid, ProcessActivatingEnv)
        elseif phase == ProcessConfiguringTestRun
            transition!(fsm_invalid, ProcessStarting)
            transition!(fsm_invalid, ProcessActivatingEnv)
            transition!(fsm_invalid, ProcessConfiguringTestRun)
        elseif phase == ProcessReadyToRun
            transition!(fsm_invalid, ProcessStarting)
            transition!(fsm_invalid, ProcessActivatingEnv)
            transition!(fsm_invalid, ProcessConfiguringTestRun)
            transition!(fsm_invalid, ProcessReadyToRun)
        elseif phase == ProcessRunning
            transition!(fsm_invalid, ProcessStarting)
            transition!(fsm_invalid, ProcessActivatingEnv)
            transition!(fsm_invalid, ProcessConfiguringTestRun)
            transition!(fsm_invalid, ProcessReadyToRun)
            transition!(fsm_invalid, ProcessRunning)
        end

        @test_throws ErrorException transition!(fsm_invalid, ProcessStarting)
    end
end

@testitem "testprocess_fsm invalid transitions" begin
    using TestItemControllers: testprocess_fsm, state, transition!,
        ProcessCreated, ProcessIdle, ProcessRunning, ProcessDead,
        ProcessActivatingEnv, ProcessConfiguringTestRun, ProcessStarting

    # ProcessIdle → ProcessRunning is not valid (must go through intermediate states)
    fsm = testprocess_fsm("proc-invalid")
    transition!(fsm, ProcessIdle)
    @test_throws ErrorException transition!(fsm, ProcessRunning)
    @test state(fsm) == ProcessIdle

    # ProcessCreated → ProcessActivatingEnv is not valid
    fsm2 = testprocess_fsm("proc-invalid-2")
    @test_throws ErrorException transition!(fsm2, ProcessActivatingEnv)
    @test state(fsm2) == ProcessCreated

    # ProcessCreated → ProcessConfiguringTestRun is not valid
    fsm3 = testprocess_fsm("proc-invalid-3")
    @test_throws ErrorException transition!(fsm3, ProcessConfiguringTestRun)
    @test state(fsm3) == ProcessCreated

    # ProcessDead → anything is not valid (terminal state)
    fsm4 = testprocess_fsm("proc-invalid-4")
    transition!(fsm4, ProcessDead)
    @test_throws ErrorException transition!(fsm4, ProcessIdle)
    @test_throws ErrorException transition!(fsm4, ProcessStarting)
    @test state(fsm4) == ProcessDead
end

@testitem "testrun_fsm valid transitions" begin
    using TestItemControllers: testrun_fsm, state, transition!,
        TestRunCreated, TestRunWaitingForProcs, TestRunProcsAcquired,
        TestRunRunning, TestRunCompleted, TestRunCancelled

    # Happy path: Created → WaitingForProcs → ProcsAcquired → Running → Completed
    fsm = testrun_fsm("run-1")
    @test state(fsm) == TestRunCreated

    transition!(fsm, TestRunWaitingForProcs)
    @test state(fsm) == TestRunWaitingForProcs

    transition!(fsm, TestRunProcsAcquired)
    @test state(fsm) == TestRunProcsAcquired

    transition!(fsm, TestRunRunning)
    @test state(fsm) == TestRunRunning

    transition!(fsm, TestRunCompleted)
    @test state(fsm) == TestRunCompleted

    # Cancellation from WaitingForProcs
    fsm2 = testrun_fsm("run-2")
    transition!(fsm2, TestRunWaitingForProcs)
    transition!(fsm2, TestRunCancelled)
    @test state(fsm2) == TestRunCancelled

    # Cancellation from ProcsAcquired
    fsm3 = testrun_fsm("run-3")
    transition!(fsm3, TestRunWaitingForProcs)
    transition!(fsm3, TestRunProcsAcquired)
    transition!(fsm3, TestRunCancelled)
    @test state(fsm3) == TestRunCancelled

    # Cancellation from Running
    fsm4 = testrun_fsm("run-4")
    transition!(fsm4, TestRunWaitingForProcs)
    transition!(fsm4, TestRunProcsAcquired)
    transition!(fsm4, TestRunRunning)
    transition!(fsm4, TestRunCancelled)
    @test state(fsm4) == TestRunCancelled
end

@testitem "testrun_fsm invalid transitions" begin
    using TestItemControllers: testrun_fsm, state, transition!,
        TestRunCreated, TestRunWaitingForProcs, TestRunProcsAcquired,
        TestRunRunning, TestRunCompleted, TestRunCancelled

    # TestRunCreated → TestRunRunning is not valid (must go through WaitingForProcs)
    fsm = testrun_fsm("run-invalid-1")
    @test_throws ErrorException transition!(fsm, TestRunRunning)
    @test state(fsm) == TestRunCreated

    # TestRunCreated → TestRunCompleted is not valid
    fsm2 = testrun_fsm("run-invalid-2")
    @test_throws ErrorException transition!(fsm2, TestRunCompleted)
    @test state(fsm2) == TestRunCreated

    # TestRunCreated → TestRunCancelled is valid (early cancellation)
    fsm3 = testrun_fsm("run-invalid-3")
    transition!(fsm3, TestRunCancelled)
    @test state(fsm3) == TestRunCancelled

    # TestRunCompleted is terminal (no valid transitions)
    fsm4 = testrun_fsm("run-invalid-4")
    transition!(fsm4, TestRunWaitingForProcs)
    transition!(fsm4, TestRunProcsAcquired)
    transition!(fsm4, TestRunRunning)
    transition!(fsm4, TestRunCompleted)
    @test_throws ErrorException transition!(fsm4, TestRunRunning)
    @test state(fsm4) == TestRunCompleted

    # TestRunCancelled is terminal
    fsm5 = testrun_fsm("run-invalid-5")
    transition!(fsm5, TestRunWaitingForProcs)
    transition!(fsm5, TestRunCancelled)
    @test_throws ErrorException transition!(fsm5, TestRunRunning)
    @test state(fsm5) == TestRunCancelled
end

@testitem "FSM transition with reason" begin
    using TestItemControllers: controller_fsm, state, transition!,
        ControllerRunning, ControllerShuttingDown

    fsm = controller_fsm("test-reason")
    @test state(fsm) == ControllerRunning

    # transition! should accept reason keyword without error
    transition!(fsm, ControllerShuttingDown; reason="user requested shutdown")
    @test state(fsm) == ControllerShuttingDown
end

@testitem "FSM error message content" begin
    using TestItemControllers: controller_fsm, transition!,
        ControllerRunning, ControllerStopped

    fsm = controller_fsm("test-error-msg")

    try
        transition!(fsm, ControllerStopped)
        @test false  # Should not reach here
    catch e
        @test e isa ErrorException
        @test occursin("Invalid FSM transition", e.msg)
        @test occursin("test-error-msg", e.msg)
        @test occursin("ControllerRunning", e.msg)
        @test occursin("ControllerStopped", e.msg)
    end
end

@testitem "FSM error message includes reason" begin
    using TestItemControllers: controller_fsm, transition!,
        ControllerRunning, ControllerStopped

    fsm = controller_fsm("test-reason-msg")

    try
        transition!(fsm, ControllerStopped; reason="test reason")
        @test false
    catch e
        @test e isa ErrorException
        @test occursin("test reason", e.msg)
    end
end

@testitem "testprocess_fsm ProcessIdle from intermediate states (cancellation)" begin
    using TestItemControllers: testprocess_fsm, state, transition!,
        ProcessCreated, ProcessIdle, ProcessReviseOrStart, ProcessRevising,
        ProcessStarting, ProcessWaitingForPrecompile, ProcessActivatingEnv,
        ProcessConfiguringTestRun, ProcessReadyToRun, ProcessRunning

    # When a test run is cancelled, processes in any intermediate setup state
    # must be able to transition back to ProcessIdle (returned to pool).
    intermediate_states = [ProcessReviseOrStart, ProcessRevising,
                           ProcessWaitingForPrecompile, ProcessActivatingEnv,
                           ProcessConfiguringTestRun, ProcessReadyToRun]

    for phase in intermediate_states
        fsm = testprocess_fsm("proc-idle-cancel-test")
        # Navigate to the target state
        if phase == ProcessReviseOrStart
            transition!(fsm, ProcessReviseOrStart)
        elseif phase == ProcessRevising
            transition!(fsm, ProcessReviseOrStart)
            transition!(fsm, ProcessRevising)
        elseif phase == ProcessWaitingForPrecompile
            transition!(fsm, ProcessStarting)
            transition!(fsm, ProcessWaitingForPrecompile)
        elseif phase == ProcessActivatingEnv
            transition!(fsm, ProcessStarting)
            transition!(fsm, ProcessActivatingEnv)
        elseif phase == ProcessConfiguringTestRun
            transition!(fsm, ProcessStarting)
            transition!(fsm, ProcessActivatingEnv)
            transition!(fsm, ProcessConfiguringTestRun)
        elseif phase == ProcessReadyToRun
            transition!(fsm, ProcessStarting)
            transition!(fsm, ProcessActivatingEnv)
            transition!(fsm, ProcessConfiguringTestRun)
            transition!(fsm, ProcessReadyToRun)
        end

        @test state(fsm) == phase
        transition!(fsm, ProcessIdle; reason="returned to pool")
        @test state(fsm) == ProcessIdle
    end
end
