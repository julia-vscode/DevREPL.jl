module TestItemControllers

import Sockets, UUIDs, Dates

include("../packages/URIParser/src/URIParser.jl")
include("../packages/CoverageTools/src/CoverageTools.jl")
include("../packages/JSON/src/JSON.jl")
include("../packages/CancellationTokens//src/CancellationTokens.jl")

module JSONRPC
    import ..CancellationTokens
    import ..JSON
    import UUIDs
    import Sockets
    include("../packages/JSONRPC/src/packagedef.jl")
end

export JSONRPCTestItemController
export TestItemController
export shutdown
export terminate_test_process
export wait_for_shutdown
export TestEnvironment, TestRunItem, TestItemDetail, TestSetupDetail
export TestMessage, TestMessageStackFrame, FileCoverage, PerfStats
export ControllerCallbacks
export execute_testrun
export TestrunResult, TestrunResultTestitem, TestrunResultTestitemProfile,
    TestrunResultMessage, TestrunResultStackFrame, TestrunResultDefinitionError,
    TestrunResultPerfStats, TestrunResultFileCoverage
export write_junit_xml, write_lcov

include("json_protocol.jl")
include("../shared/testserver_protocol.jl")
include("../shared/urihelper.jl")

include("datatypes.jl")
include("results.jl")
using .Results
include("junit.jl")
include("lcov.jl")
include("testenvironment.jl")

include("fsm.jl")
include("messages.jl")
include("callbacks.jl")
include("state.jl")

include("testprocess.jl")
include("testitemcontroller.jl")
include("scheduling.jl")
include("jsonrpctestitemcontroller.jl")

include("precompile.jl")

end # module TestItemControllers
