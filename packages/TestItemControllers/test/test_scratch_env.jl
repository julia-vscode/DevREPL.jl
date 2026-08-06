@testmodule ScratchEnvHelpers begin
    """
        snapshot(dir) -> Dict{String,Any}

    A recursive listing of `dir`: relative path => file content (or `:dir`).
    Comparing two snapshots catches both new files and modified ones.
    """
    function snapshot(dir::String)
        result = Dict{String,Any}()
        for (root, dirs, files) in walkdir(dir)
            for d in dirs
                result[relpath(joinpath(root, d), dir)] = :dir
            end
            for f in files
                path = joinpath(root, f)
                result[relpath(path, dir)] = read(path, String)
            end
        end
        return result
    end

    """
        materialize_package(dest; name, uuid) -> String

    Write a minimal package with one passing test item into `dest`. The test
    dependency comes in through `[extras]`/`[targets]`, the shape virtually every
    real package has and the one that constrains what the scratch environment may
    strip from a mirrored `Project.toml`.
    """
    function materialize_package(dest::String; name::String, uuid::String)
        mkpath(joinpath(dest, "src"))
        mkpath(joinpath(dest, "test"))

        write(joinpath(dest, "Project.toml"), """
        name = "$name"
        uuid = "$uuid"
        version = "0.1.0"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [compat]
        Test = "1"
        julia = "1"

        [targets]
        test = ["Test"]
        """)

        write(joinpath(dest, "src", "$name.jl"), """
        module $name
        greet() = "hello from $name"
        end
        """)

        write(joinpath(dest, "test", "tests.jl"), """
        @testitem "$name greets" begin
            using $name
            @test $name.greet() == "hello from $name"
        end
        """)

        return dest
    end

    passed_ids(result) = [e.testitem_id for e in result.events if e.event == :passed]

    function error_messages(result)
        msgs = String[]
        for e in result.events
            e.event == :errored || continue
            for m in e.messages
                push!(msgs, m.message)
            end
        end
        return msgs
    end
end

# The implementation under test lives in the test process, which the controller
# test suite never loads. It only needs `Pkg`, so include it directly.
@testmodule ScratchEnvImpl begin
    import Pkg
    include(joinpath(@__DIR__, "..", "testprocess", "TestItemServer", "src", "scratch_env.jl"))
end

@testitem "materialize_scratch_env strips package identity" setup=[ScratchEnvHelpers, ScratchEnvImpl] begin
    import Pkg

    work = mktempdir()
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "Stripped");
        name="Stripped",
        uuid="a1b2c3d4-0001-0002-0003-000000000201"
    )

    env = ScratchEnvImpl.materialize_scratch_env(pkg_path, "Stripped")
    project = Pkg.TOML.parsefile(joinpath(env.dir, "Project.toml"))

    # Nameless, so that Pkg cannot derive the package's source location from the
    # scratch directory (which has no `src/` and no `test/`).
    @test !haskey(project, "name")
    @test !haskey(project, "uuid")
    @test !haskey(project, "version")

    # `[extras]`/`[targets]` belong to the real package; TestEnv reads the test
    # target from there, not from the active environment.
    @test !haskey(project, "extras")
    @test !haskey(project, "targets")

    # The package itself becomes an ordinary dependency.
    @test project["deps"]["Stripped"] == "a1b2c3d4-0001-0002-0003-000000000201"

    # Compat bounds on a dropped extra would make Pkg reject the whole file.
    @test !haskey(get(project, "compat", Dict()), "Test")
    @test get(project, "compat", Dict())["julia"] == "1"

    # And the result has to be something Pkg will actually read back.
    @test Pkg.Types.read_project(joinpath(env.dir, "Project.toml")) isa Pkg.Types.Project
end

@testitem "materialize_scratch_env makes mirrored paths absolute" setup=[ScratchEnvHelpers, ScratchEnvImpl] begin
    import Pkg

    # A nameless environment that devs a package sitting next to it — the
    # monorepo shape. Both the manifest path and (where supported) the `[sources]`
    # path are recorded relative to the file they live in, so both have to be
    # rewritten before the environment moves.
    work = mktempdir()
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "packages", "Relative");
        name="Relative",
        uuid="a1b2c3d4-0001-0002-0003-000000000202"
    )

    project_path = joinpath(work, "env")
    mkpath(project_path)
    write(joinpath(project_path, "Project.toml"), """
    [deps]
    Relative = "a1b2c3d4-0001-0002-0003-000000000202"
    """)
    write(joinpath(project_path, "Manifest.toml"), """
    julia_version = "$(VERSION)"
    manifest_format = "2.0"
    project_hash = "0000000000000000000000000000000000000000"

    [[deps.Relative]]
    path = "../packages/Relative"
    uuid = "a1b2c3d4-0001-0002-0003-000000000202"
    version = "0.1.0"
    """)

    env = ScratchEnvImpl.materialize_scratch_env(project_path, "Relative")

    manifest = Pkg.TOML.parsefile(joinpath(env.dir, "Manifest.toml"))
    @test manifest["deps"]["Relative"][1]["path"] == normpath(pkg_path)

    # Recorded against the source project's dependency list, which the wrapper's
    # differs from; Pkg treats its absence as "unknown" and stays quiet.
    @test !haskey(manifest, "project_hash")

    project = Pkg.TOML.parsefile(joinpath(env.dir, "Project.toml"))
    @test project["sources"]["Relative"]["path"] == normpath(pkg_path)

    @test env.develop_path === nothing
    @test Pkg.Types.read_manifest(joinpath(env.dir, "Manifest.toml")) isa Pkg.Types.Manifest
end

@testitem "materialize_scratch_env carries LocalPreferences.toml along" setup=[ScratchEnvHelpers, ScratchEnvImpl] begin
    work = mktempdir()
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "Preferred");
        name="Preferred",
        uuid="a1b2c3d4-0001-0002-0003-000000000203"
    )
    write(joinpath(pkg_path, "LocalPreferences.toml"), """
    [Preferred]
    flavour = "vanilla"
    """)

    env = ScratchEnvImpl.materialize_scratch_env(pkg_path, "Preferred")

    mirrored = joinpath(env.dir, "LocalPreferences.toml")
    @test isfile(mirrored)
    @test occursin("vanilla", read(mirrored, String))
end

@testitem "No preferences means no carrier environment" setup=[ScratchEnvHelpers, ScratchEnvImpl] begin
    work = mktempdir()
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "Plain");
        name="Plain",
        uuid="a1b2c3d4-0001-0002-0003-000000000206"
    )

    env = ScratchEnvImpl.materialize_scratch_env(pkg_path, "Plain")

    # Nothing to carry, so nothing gets appended to the test process' `LOAD_PATH`.
    @test env.preferences_dir === nothing
end

@testitem "The preferences carrier survives the active project being swapped" setup=[ScratchEnvHelpers, ScratchEnvImpl] begin
    import Pkg

    # What `TestEnv.activate` does to us: it makes a temporary directory of its
    # own the active project, so the copy of `LocalPreferences.toml` sitting next
    # to the scratch project stops being reachable. The carrier goes on
    # `LOAD_PATH`, which TestEnv leaves alone.
    work = mktempdir()
    uuid = "a1b2c3d4-0001-0002-0003-000000000207"
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "Carried");
        name="Carried",
        uuid=uuid
    )
    write(joinpath(pkg_path, "LocalPreferences.toml"), """
    [Carried]
    flavour = "vanilla"
    """)

    env = ScratchEnvImpl.materialize_scratch_env(pkg_path, "Carried")

    carrier = env.preferences_dir
    @test carrier !== nothing

    project = Pkg.TOML.parsefile(joinpath(carrier, "Project.toml"))

    # `Base.collect_preferences` maps the UUID it is given to a package name via
    # the project file of the environment it is looking at, and skips the
    # environment entirely when that fails.
    @test project["extras"]["Carried"] == uuid

    # In `[extras]` rather than `[deps]`, and with no manifest: the carrier can
    # never satisfy an `import`, it only ever contributes preferences.
    @test !haskey(project, "deps")
    @test !isfile(joinpath(carrier, "Manifest.toml"))

    @test occursin("vanilla", read(joinpath(carrier, "LocalPreferences.toml"), String))

    saved_project = Base.ACTIVE_PROJECT[]
    saved_load_path = copy(LOAD_PATH)
    try
        unrelated = mktempdir()
        write(joinpath(unrelated, "Project.toml"), "")
        Base.ACTIVE_PROJECT[] = joinpath(unrelated, "Project.toml")

        # Without the carrier the preference is gone at this point...
        @test !haskey(Base.get_preferences(Base.UUID(uuid)), "flavour")

        # ...and with it appended it resolves again, which is all Preferences.jl
        # and every precompilation subprocess ever ask for.
        push!(LOAD_PATH, carrier)
        @test Base.get_preferences(Base.UUID(uuid))["flavour"] == "vanilla"
    finally
        Base.ACTIVE_PROJECT[] = saved_project
        append!(empty!(LOAD_PATH), saved_load_path)
    end
end

@testitem "The preferences carrier includes the project's own [preferences]" setup=[ScratchEnvHelpers, ScratchEnvImpl] begin
    import Pkg

    # The other tier Preferences.jl reads: a `[preferences]` section inside the
    # project file itself. Both are carried over separately, so that the merge —
    # `[preferences]` first, `LocalPreferences.toml` on top — stays `Base`'s to do.
    work = mktempdir()
    uuid = "a1b2c3d4-0001-0002-0003-000000000208"
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "Embedded");
        name="Embedded",
        uuid=uuid
    )
    open(joinpath(pkg_path, "Project.toml"), "a") do io
        print(io, """

        [preferences.Embedded]
        flavour = "chocolate"
        topping = "sprinkles"
        """)
    end
    write(joinpath(pkg_path, "LocalPreferences.toml"), """
    [Embedded]
    flavour = "vanilla"
    """)

    env = ScratchEnvImpl.materialize_scratch_env(pkg_path, "Embedded")
    carrier = env.preferences_dir
    @test carrier !== nothing

    project = Pkg.TOML.parsefile(joinpath(carrier, "Project.toml"))
    @test project["preferences"]["Embedded"]["topping"] == "sprinkles"

    saved_project = Base.ACTIVE_PROJECT[]
    saved_load_path = copy(LOAD_PATH)
    try
        unrelated = mktempdir()
        write(joinpath(unrelated, "Project.toml"), "")
        Base.ACTIVE_PROJECT[] = joinpath(unrelated, "Project.toml")
        push!(LOAD_PATH, carrier)

        prefs = Base.get_preferences(Base.UUID(uuid))
        @test prefs["topping"] == "sprinkles"
        # The local file wins over the project section, as it does everywhere else.
        @test prefs["flavour"] == "vanilla"
    finally
        Base.ACTIVE_PROJECT[] = saved_project
        append!(empty!(LOAD_PATH), saved_load_path)
    end
end

@testitem "materialize_scratch_env drops a manifest Pkg cannot read" setup=[ScratchEnvHelpers, ScratchEnvImpl] begin
    # A manifest resolved by a different Julia can be in a format this one does
    # not understand. Copying it verbatim would make `Pkg.activate` itself throw,
    # so it is dropped and the scratch environment resolves from the project
    # alone — exactly what happens for an environment that has no manifest.
    work = mktempdir()
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "Futuristic");
        name="Futuristic",
        uuid="a1b2c3d4-0001-0002-0003-000000000205"
    )
    import Pkg
    write(joinpath(pkg_path, "Manifest.toml"), """
    manifest_format = "9.0"

    [[deps.Futuristic]]
    uuid = "not-a-uuid"
    """)

    env = ScratchEnvImpl.materialize_scratch_env(pkg_path, "Futuristic")

    @test !isfile(joinpath(env.dir, "Manifest.toml"))
    # And what remains is a project Pkg will happily activate.
    @test Pkg.Types.read_project(joinpath(env.dir, "Project.toml")) isa Pkg.Types.Project
end

@testitem "materialize_scratch_env only reads the source environment" setup=[ScratchEnvHelpers, ScratchEnvImpl] begin
    work = mktempdir()
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "ReadOnly");
        name="ReadOnly",
        uuid="a1b2c3d4-0001-0002-0003-000000000204"
    )

    before = ScratchEnvHelpers.snapshot(pkg_path)
    ScratchEnvImpl.materialize_scratch_env(pkg_path, "ReadOnly")
    @test ScratchEnvHelpers.snapshot(pkg_path) == before
end

@testitem "A test run does not write into the package folder" setup=[TestHelpers, ScratchEnvHelpers] begin
    # The package has a `Project.toml` but no `Manifest.toml`, which is the shape
    # that used to make `TestEnv.activate`'s `Pkg.instantiate` resolve a manifest
    # straight into the user's working tree.
    work = mktempdir()
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "Untouched");
        name="Untouched",
        uuid="a1b2c3d4-0001-0002-0003-000000000101"
    )

    before = ScratchEnvHelpers.snapshot(pkg_path)

    discovered = TestHelpers.discover_test_items(pkg_path)
    @test length(discovered.items) == 1

    result = TestHelpers.run_testrun(discovered)

    @test length(ScratchEnvHelpers.passed_ids(result)) == 1
    @test isempty(ScratchEnvHelpers.error_messages(result))

    @test !isfile(joinpath(pkg_path, "Manifest.toml"))
    @test ScratchEnvHelpers.snapshot(pkg_path) == before
end

@testitem "A test run does not modify an existing manifest" setup=[TestHelpers, ScratchEnvHelpers] begin
    work = mktempdir()
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "Pinned");
        name="Pinned",
        uuid="a1b2c3d4-0001-0002-0003-000000000102"
    )

    # Written by hand rather than by Pkg so the test does not depend on the depot.
    write(joinpath(pkg_path, "Manifest.toml"), """
    julia_version = "$(VERSION)"
    manifest_format = "2.0"
    project_hash = "0000000000000000000000000000000000000000"

    [[deps.Pinned]]
    path = "."
    uuid = "a1b2c3d4-0001-0002-0003-000000000102"
    version = "0.1.0"
    """)

    before = ScratchEnvHelpers.snapshot(pkg_path)

    discovered = TestHelpers.discover_test_items(pkg_path)
    result = TestHelpers.run_testrun(discovered)

    @test length(ScratchEnvHelpers.passed_ids(result)) == 1
    @test ScratchEnvHelpers.snapshot(pkg_path) == before
end

@testitem "A test run does not write into a separate project folder" setup=[TestHelpers, ScratchEnvHelpers] begin
    using TestItemControllers: filepath2uri

    # The monorepo shape: a nameless environment that devs the package under
    # test. Here both folders have to survive the run untouched.
    work = mktempdir()
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "packages", "Member");
        name="Member",
        uuid="a1b2c3d4-0001-0002-0003-000000000103"
    )

    project_path = joinpath(work, "env")
    mkpath(project_path)
    write(joinpath(project_path, "Project.toml"), """
    [deps]
    Member = "a1b2c3d4-0001-0002-0003-000000000103"
    """)
    write(joinpath(project_path, "Manifest.toml"), """
    julia_version = "$(VERSION)"
    manifest_format = "2.0"

    [[deps.Member]]
    path = "../packages/Member"
    uuid = "a1b2c3d4-0001-0002-0003-000000000103"
    version = "0.1.0"
    """)

    pkg_before = ScratchEnvHelpers.snapshot(pkg_path)
    project_before = ScratchEnvHelpers.snapshot(project_path)

    discovered = TestHelpers.discover_test_items(pkg_path)
    @test length(discovered.items) == 1

    result = TestHelpers.run_testrun(
        discovered.items,
        discovered.setups;
        package_name="Member",
        package_uri=filepath2uri(pkg_path),
        project_uri=filepath2uri(project_path)
    )

    @test length(ScratchEnvHelpers.passed_ids(result)) == 1
    @test isempty(ScratchEnvHelpers.error_messages(result))

    @test ScratchEnvHelpers.snapshot(pkg_path) == pkg_before
    @test ScratchEnvHelpers.snapshot(project_path) == project_before
end

@testitem "Test items run against a copy of the environment, not the original" setup=[TestHelpers, ScratchEnvHelpers] begin
    work = mktempdir()
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "Elsewhere");
        name="Elsewhere",
        uuid="a1b2c3d4-0001-0002-0003-000000000105"
    )

    write(joinpath(pkg_path, "test", "tests.jl"), """
    @testitem "active project is not the package folder" begin
        using Elsewhere
        # `samefile` rather than `==`: the path round-trips through a file URI,
        # which lower-cases the Windows drive letter.
        @test Base.Filesystem.samefile(dirname(dirname(pathof(Elsewhere))), raw"$(pkg_path)")
        # The package still loads from its real location, but the environment we
        # resolve (and could write) against is not the user's folder.
        @test !Base.Filesystem.samefile(dirname(Base.active_project()), raw"$(pkg_path)")
        @test Elsewhere.greet() == "hello from Elsewhere"
    end
    """)

    discovered = TestHelpers.discover_test_items(pkg_path)
    result = TestHelpers.run_testrun(discovered)

    @test length(ScratchEnvHelpers.passed_ids(result)) == 1
    @test isempty(ScratchEnvHelpers.error_messages(result))
end

@testitem "A test item sees the package's LocalPreferences.toml" setup=[TestHelpers, ScratchEnvHelpers] begin
    work = mktempdir()
    uuid = "a1b2c3d4-0001-0002-0003-000000000106"
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "Flavoured");
        name="Flavoured",
        uuid=uuid
    )
    write(joinpath(pkg_path, "LocalPreferences.toml"), """
    [Flavoured]
    flavour = "vanilla"
    """)

    # `Base.get_preferences` is what `Preferences.load_preference` calls, and what
    # decides whether e.g. PrecompileTools runs a package's workload while the
    # test process precompiles it.
    write(joinpath(pkg_path, "test", "tests.jl"), """
    @testitem "preferences are visible" begin
        prefs = Base.get_preferences(Base.UUID("$uuid"))
        @test get(prefs, "flavour", nothing) == "vanilla"
    end
    """)

    discovered = TestHelpers.discover_test_items(pkg_path)
    result = TestHelpers.run_testrun(discovered)

    @test length(ScratchEnvHelpers.passed_ids(result)) == 1
    @test isempty(ScratchEnvHelpers.error_messages(result))
end

@testitem "A test item sees a separate project's LocalPreferences.toml" setup=[TestHelpers, ScratchEnvHelpers] begin
    using TestItemControllers: filepath2uri

    # Issue #28: the preference lives in the project environment the user
    # configured, not in the package folder, and the package under test is one of
    # that environment's deved dependencies.
    work = mktempdir()
    uuid = "a1b2c3d4-0001-0002-0003-000000000107"
    pkg_path = ScratchEnvHelpers.materialize_package(
        joinpath(work, "packages", "Seasoned");
        name="Seasoned",
        uuid=uuid
    )

    project_path = joinpath(work, "env")
    mkpath(project_path)
    write(joinpath(project_path, "Project.toml"), """
    [deps]
    Seasoned = "$uuid"
    """)
    write(joinpath(project_path, "Manifest.toml"), """
    julia_version = "$(VERSION)"
    manifest_format = "2.0"

    [[deps.Seasoned]]
    path = "../packages/Seasoned"
    uuid = "$uuid"
    version = "0.1.0"
    """)
    write(joinpath(project_path, "LocalPreferences.toml"), """
    [Seasoned]
    flavour = "vanilla"
    """)

    write(joinpath(pkg_path, "test", "tests.jl"), """
    @testitem "preferences are visible" begin
        prefs = Base.get_preferences(Base.UUID("$uuid"))
        @test get(prefs, "flavour", nothing) == "vanilla"
    end
    """)

    project_before = ScratchEnvHelpers.snapshot(project_path)

    discovered = TestHelpers.discover_test_items(pkg_path)
    @test length(discovered.items) == 1

    result = TestHelpers.run_testrun(
        discovered.items,
        discovered.setups;
        package_name="Seasoned",
        package_uri=filepath2uri(pkg_path),
        project_uri=filepath2uri(project_path)
    )

    @test length(ScratchEnvHelpers.passed_ids(result)) == 1
    @test isempty(ScratchEnvHelpers.error_messages(result))

    # Reading preferences must not have made us write anything either.
    @test ScratchEnvHelpers.snapshot(project_path) == project_before
end
