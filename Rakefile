# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "standard/rake"

task :ratchet do
  sh "bin/ratchet"
end

task default: %i[spec standard ratchet]
