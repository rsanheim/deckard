# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "standard/rake"

task :ratchet do
  sh "bin/ratchet"
end

desc "End-to-end test: real apps and databases entirely inside docker compose"
task :e2e do
  sh "harness/bin/stream_test"
end

desc "Run lint, host tests, and the end-to-end Docker harness"
task "test-all" => %i[standard spec ratchet e2e]

desc "Performance tests (slow; excluded from the default suite)"
task :perf do
  sh "bundle exec rspec --tag perf spec/perf"
end

# Test-database tasks over ActiveRecord::Tasks::DatabaseTasks, configured
# in spec/support/database.rb. Migrations live in spec/db/migrate and
# db:migrate regenerates spec/db/schema.rb, which the specs load.
namespace :db do
  task :config do
    require_relative "spec/support/database"
    ActiveRecord::Base.establish_connection(DeckardTestDatabase.primary_config)
  end

  desc "Create the test databases"
  task create: :config do
    DeckardTestDatabase::Tasks.create_current
  end

  desc "Drop the test databases"
  task drop: :config do
    DeckardTestDatabase::Tasks.drop_current
  end

  desc "Run pending migrations against the test databases and dump spec/db/schema.rb"
  task migrate: :config do
    tasks = DeckardTestDatabase::Tasks
    tasks.with_temporary_pool_for_each { tasks.migrate }
    tasks.dump_schema(DeckardTestDatabase.primary_config)
  end

  desc "Load spec/db/schema.rb into the test databases"
  task "schema:load" => :config do
    tasks = DeckardTestDatabase::Tasks
    tasks.with_temporary_pool_for_each do |pool|
      tasks.load_schema(pool.db_config, :ruby, DeckardTestDatabase::SCHEMA)
    end
  end

  desc "Load spec/db/seeds.rb into the primary test database"
  task seed: :config do
    require "deckard"
    require_relative "spec/support/forum_models"
    DeckardTestDatabase.configure_encryption
    DeckardTestDatabase::Tasks.load_seed
  end

  desc "Drop, create, migrate, and seed the test databases"
  task reset: %w[db:drop db:create db:migrate db:seed]
end

task default: %i[spec standard ratchet]
