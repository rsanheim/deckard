# frozen_string_literal: true

require "database_cleaner/active_record"
require_relative "test_database"

# Cleans the test database around each `:db`-tagged example. Transactions
# are the default (fastest); tag an example `db: :truncation` when its
# writes must escape or observe a real transaction boundary (rollback
# assertions, subprocesses, perf measurements).
RSpec.configure do |config|
  config.before(:each, :db) do |example|
    DeckardTestDatabase.setup
    DatabaseCleaner.strategy = (example.metadata[:db] == :truncation) ? :truncation : :transaction
    DatabaseCleaner.start
  end

  config.after(:each, :db) do
    DatabaseCleaner.clean
  end
end
