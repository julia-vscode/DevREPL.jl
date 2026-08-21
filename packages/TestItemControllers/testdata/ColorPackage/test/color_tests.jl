# Fixture for the tests around the `color` field of a test environment.
#
# `printstyled` only emits escapes when the stream it writes to says it understands them,
# and a test process writes to a pipe — so this item's output is plain unless the process
# was started with `--color=yes`.

@testitem "colored output" begin
    printstyled("a red line\n"; color=:red)
    @test true
end
