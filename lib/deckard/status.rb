# frozen_string_literal: true

module Deckard
  # Writes completion counts to standard error: a total line, then per-type
  # counts sorted by type name. Standard output is never touched - it
  # belongs to the stream.
  class Status
    def self.report(action, counts, stderr)
      stderr.puts "#{action} #{counts.values.sum} total objects:"
      return if counts.empty?

      stderr.puts
      name_width = counts.keys.map(&:length).max + 2
      count_width = counts.values.max.to_s.length
      counts.sort.each do |type, count|
        stderr.puts "#{type.ljust(name_width)}#{count.to_s.rjust(count_width)}"
      end
    end
  end
end
