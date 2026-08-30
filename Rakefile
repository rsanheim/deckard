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

desc "Performance tests (slow; excluded from the default suite)"
task :perf do
  sh({"DECKARD_PERF" => "1"}, "bundle exec rspec spec/perf")
end

task default: %i[spec standard ratchet]
