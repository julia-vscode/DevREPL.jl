module HangingPackage

# Fixture for shutdown tests: its test items deliberately never finish and, where the
# platform allows it, ignore SIGTERM, so that only a forced kill brings the process down.

end
