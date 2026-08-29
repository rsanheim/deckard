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

task default: %i[spec standard ratchet]
