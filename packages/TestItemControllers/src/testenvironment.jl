struct ProcessEnv
    project_uri:: Union{Nothing,String}
    package_uri::String
    package_name::String
    juliaCmd::String
    juliaArgs::Vector{String}
    juliaNumThreads::Union{Nothing,String}
    mode::String
    env::Dict{String,Union{String,Nothing}}
    check_bounds::String
    color::Bool
end

ProcessEnv(project_uri, package_uri, package_name, juliaCmd, juliaArgs, juliaNumThreads, mode, env) =
    ProcessEnv(project_uri, package_uri, package_name, juliaCmd, juliaArgs, juliaNumThreads, mode, env, "auto", false)

ProcessEnv(project_uri, package_uri, package_name, juliaCmd, juliaArgs, juliaNumThreads, mode, env, check_bounds::AbstractString) =
    ProcessEnv(project_uri, package_uri, package_name, juliaCmd, juliaArgs, juliaNumThreads, mode, env, check_bounds, false)

function ProcessEnv(env::TestEnvironment)
    return ProcessEnv(
        env.project_uri,
        env.package_uri,
        env.package_name,
        env.julia_cmd,
        env.julia_args,
        env.julia_num_threads,
        env.mode,
        env.julia_env,
        something(env.check_bounds, "auto"),
        env.color
    )
end

Base.hash(x::ProcessEnv, h::UInt) = hash(x.color, hash(x.check_bounds, hash(x.env, hash(x.mode, hash(x.juliaNumThreads, hash(x.juliaArgs, hash(x.juliaCmd, hash(x.package_name, hash(x.package_uri, hash(x.project_uri, hash(:ProcessEnv, h)))))))))))
Base.:(==)(a::ProcessEnv, b::ProcessEnv) = a.project_uri == b.project_uri && a.package_uri == b.package_uri && a.package_name == b.package_name && a.juliaCmd == b.juliaCmd && a.juliaArgs == b.juliaArgs && a.juliaNumThreads == b.juliaNumThreads && a.mode == b.mode && a.env == b.env && a.check_bounds == b.check_bounds && a.color == b.color
Base.isequal(a::ProcessEnv, b::ProcessEnv) = isequal(a.project_uri, b.project_uri) && isequal(a.package_uri, b.package_uri) && isequal(a.package_name, b.package_name) && isequal(a.juliaCmd, b.juliaCmd) && isequal(a.juliaArgs, b.juliaArgs) && isequal(a.juliaNumThreads, b.juliaNumThreads) && isequal(a.mode, b.mode) && isequal(a.env, b.env) && isequal(a.check_bounds, b.check_bounds) && isequal(a.color, b.color)
