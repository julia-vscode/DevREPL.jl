using TestItemRunner

# The vendored subtrees under packages/ carry their own test suites; only run
# the test items that live in this test/ folder.
@run_package_tests filter=ti -> startswith(ti.filename, @__DIR__)
