# Compile shared test support files
Code.require_file("test/support/shared_tests.ex")
Code.require_file("test/support/telemetry_helper.ex")

ExUnit.start()
