@testitem "TestEnvironment with empty package info" setup=[TestHelpers] begin
    using TestItemControllers: TestEnvironment

    # With the new model, package info lives on TestEnvironment.
    # An environment with empty package name/uri is valid to construct,
    # but will fail during activation (package not found).
    env = TestHelpers.make_test_environment()
    @test env.package_name == ""
    @test env.package_uri == ""
    @test env.project_uri === nothing
    @test env.env_content_hash === nothing
end
