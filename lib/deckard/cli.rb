# frozen_string_literal: true

require "optimist"
require_relative "status"

module Deckard
  # The deckard executable: -r requires the application environment, -d
  # dumps a Ruby expression or dump script to stdout, -l loads a stream
  # from stdin. Required from exe/deckard, not from the library itself.
  class CLI
    def self.run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      new(stdin: stdin, stdout: stdout, stderr: stderr).run(argv)
    end

    # Evaluation context for dump scripts: exposes only dump(object, options).
    class DumpScript
      def initialize(dumper)
        @dumper = dumper
      end

      def dump(object, options = {})
        @dumper.dump(object, options)
      end
    end

    def initialize(stdin:, stdout:, stderr:)
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
    end

    def run(argv)
      options = parse(argv)
      reserve_stdout if options[:dump]
      require File.expand_path(options[:require]) if options[:require]

      options[:dump] ? dump(options[:dump]) : load_stream(options)
      0
    rescue Error => e
      @stderr.puts "#{e.class}: #{e.message}"
      1
    rescue Errno::EPIPE
      @stderr.puts "deckard: output pipe closed before the stream completed"
      1
    end

    private

    # Application boot code may print to stdout, which would corrupt the
    # stream. Keep a private copy of the original stdout for the dumper and
    # point file descriptor 1 at stderr, so anything else this process or
    # its children write to stdout lands on stderr instead.
    # rubocop:disable Style/GlobalStdStream -- the process-level streams are the point
    def reserve_stdout
      return unless @stdout.equal?(STDOUT)

      @stdout = STDOUT.dup
      STDOUT.reopen(STDERR)
      $stdout = STDOUT
    end
    # rubocop:enable Style/GlobalStdStream

    def parse(argv)
      options = Optimist.options(argv) do
        version "deckard #{VERSION}"
        banner <<~BANNER
          deckard: stream ActiveRecord objects between Rails environments

            dump:  deckard -r ./config/environment -d "User.find(1)" > user.dump
            load:  deckard -r ./config/environment -l < user.dump
            pipe:  ssh example.org "deckard -r /app/config/environment -d 'User.find(1)'" | deckard -r ./config/environment -l

          Options:
        BANNER
        opt :require, "Ruby file to require first (usually config/environment)", type: :string
        opt :dump, "Dump the result of a Ruby expression, or run a dump script file", type: :string
        opt :load, "Load a deckard stream from standard input"
        opt :force, "Allow loading into a production environment"
      end

      unless !options[:dump].nil? ^ options[:load]
        Optimist.die "exactly one of -d or -l is required"
      end
      options
    end

    def dump(target)
      @stdout.binmode if @stdout.respond_to?(:binmode)
      dumper = Dumper.new(@stdout)

      if File.exist?(target)
        DumpScript.new(dumper).instance_eval(File.read(target), target)
      else
        dumper.dump(eval(target, TOPLEVEL_BINDING.dup, "deckard -d")) # rubocop:disable Security/Eval -- -d takes trusted operator Ruby by design
      end

      dumper.complete
      @stdout.flush
      Status.report("dumped", dumper.counts, @stderr)
    end

    def load_stream(options)
      if Deckard.production_environment? && !options[:force]
        raise LoadError, "refusing to load into a production environment (pass --force to override)"
      end

      @stdin.binmode if @stdin.respond_to?(:binmode)
      loader = Loader.new(@stdin)
      loader.load
      Status.report("loaded", loader.counts, @stderr)
    end
  end
end
