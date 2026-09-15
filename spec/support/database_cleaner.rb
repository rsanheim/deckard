# frozen_string_literal: true

require "database_cleaner/active_record"
require_relative "database"

# Cleans the test database around each `:db`-tagged example. Transactions
# are the default (fastest); tag an example `db: :truncation` when its
# writes must escape or observe a real transaction boundary, or
# `db: :multiple` when it uses both test databases.
RSpec.configure do |config|
  config.around(:each, :db) do |example|
    DeckardTestDatabase.setup
    cleaners = DatabaseCleaner::Cleaners.new

    if example.metadata[:db] == :multiple
      DeckardTestDatabase.setup_destination
      cleaners[:active_record, db: DeckardTestDatabase::SourceRecord].strategy = :truncation
      cleaners[:active_record, db: DeckardTestDatabase::DestinationRecord].strategy = :truncation
      cleaners.clean_with(:truncation)
    else
      strategy = (example.metadata[:db] == :truncation) ? :truncation : :transaction
      cleaners[:active_record, db: ActiveRecord::Base].strategy = strategy
    end

    cleaners.cleaning { example.run }
  end
end
