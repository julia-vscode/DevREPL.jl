using TestItemRunner

ENV["JULIA_DEBUG"] = "TestItemControllers"

@run_package_tests filter = ti -> startswith(ti.filename, joinpath(@__DIR__, "")) && !(:comprehensive_platform in ti.tags)
