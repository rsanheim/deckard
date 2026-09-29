# frozen_string_literal: true

require "json"

puts "application booted" if ENV["DECKARD_BOOT_LOG"] == "1"

# A Zeitwerk-managed directory nothing references: only eager loading brings
# its constants in, which the CLI must do so every replicate block runs.
require "zeitwerk"
autoloader = Zeitwerk::Loader.new
autoloader.push_dir(File.expand_path("cli_autoload", __dir__))
autoloader.push_dir(File.expand_path("cli_autoload_broken", __dir__)) if ENV["DECKARD_BROKEN_PLAN"] == "1"
autoloader.setup

# Plain-Ruby replicant classes for the CLI subprocess specs. Loading appends
# JSON lines to the file named by DECKARD_CLI_OUT, so the parent spec
# process can observe what a separate load process did.
class CliWidget
  attr_reader :id, :name

  def initialize(id:, name:)
    @id = id
    @name = name
  end

  def dump_replicant(dumper)
    dumper.write(self.class, id, {"name" => name})
  end

  def self.load_replicant(type, source_id, attributes, natural_key)
    File.open(ENV.fetch("DECKARD_CLI_OUT"), "a") do |file|
      file.puts JSON.generate("type" => type, "source_id" => source_id, "attributes" => attributes)
    end
    [source_id + 1000, nil]
  end
end

WIDGETS = [CliWidget.new(id: 1, name: "flux"), CliWidget.new(id: 2, name: "capacitor")]

# Lazily yields enough widgets to overrun a pipe buffer, for the
# broken-pipe spec. Costs nothing unless iterated.
BIG_WIDGETS = Enumerator.new do |yielder|
  10_000.times { |i| yielder << CliWidget.new(id: i, name: "widget-#{i}-#{"x" * 40}") }
end
