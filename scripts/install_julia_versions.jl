for minor in 0:13
    version = "1.$minor"
    println("Installing Julia $version...")
    run(ignorestatus(`juliaup add $version`))
end
