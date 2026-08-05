@info "Julia test item process launching"

# Activate the version-specific environment. We use Base.ACTIVE_PROJECT[]
# (available since Julia 1.0) instead of Pkg.activate, because Pkg may not
# be available in the default environment on Julia 1.12+ (no implicit Pkg
# in empty projects). Fall back to Pkg.activate for safety.
version_specific_env_path = joinpath(@__DIR__, "../environments", "v$(VERSION.major).$(VERSION.minor)")
let env_path = isdir(version_specific_env_path) ? version_specific_env_path : joinpath(@__DIR__, "../environments", "fallback")
    if isdefined(Base, :ACTIVE_PROJECT)
        Base.ACTIVE_PROJECT[] = env_path
    else
        import Pkg
        Pkg.activate(env_path)
    end
end

let
    has_error_handler = false

    try

        if length(ARGS) > 2
            include(ARGS[3])
            has_error_handler = true
        end

        using TestItemServer

        TestItemServer.serve(
            ARGS[1],
            ARGS[2],
            has_error_handler ? (err, bt) -> Base.invokelatest(global_err_handler, err, bt, Base.ARGS[4], "Test Process") : nothing)
    catch err
        if has_error_handler
            Base.invokelatest(global_err_handler, err, catch_backtrace(), Base.ARGS[4], "Test Process")
        end
        
        rethrow()
    end
end
