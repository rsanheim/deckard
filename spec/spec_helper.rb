# frozen_string_literal: true

require "deckard"
require_relative "support/stream_helpers"

RSpec.configure do |config|
  config.include StreamHelpers

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Performance tests are slow and only run via `rake perf`.
  config.filter_run_excluding perf: true
end
