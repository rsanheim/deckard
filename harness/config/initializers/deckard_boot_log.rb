# Simulates an application that logs to stdout while booting. The stream
# test sets DECKARD_HARNESS_BOOT_LOG=1 to prove deckard keeps this out of
# the dump stream.
puts "application booted" if ENV["DECKARD_HARNESS_BOOT_LOG"] == "1"
