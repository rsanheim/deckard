# frozen_string_literal: true

require "optimist"
require "tempfile"
require_relative "status"

module Deckard
  # The deckard executable: -r requires the application environment, -d
  # dumps a Ruby expression or dump script to a selected output channel, and
  # -l loads a stream from stdin. Required from exe/deckard, not the library.
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
      options[:output] = File.expand_path(options[:output]) if options[:output]
      require File.expand_path(options[:require]) if options[:require]

      options[:dump] ? dump_command(options) : load_stream
      0
    rescue Error => e
      @stderr.puts "#{e.class}: #{e.message}"
      1
    rescue Errno::EPIPE
      @stderr.puts "deckard: output pipe closed before the stream completed"
      1
    end

    private

    def parse(argv)
      options = Optimist.options(argv) do
        version "deckard #{VERSION}"
        banner <<~BANNER
          deckard: stream ActiveRecord objects between Rails environments

            dump:  deckard -r ./config/environment -d "User.find(1)" > user.dump
            file:  deckard -r ./config/environment -d "User.find(1)" --output user.dump
            load:  deckard -r ./config/environment -l < user.dump
            pipe:  ssh example.org "deckard -r /app/config/environment -d 'User.find(1)'" | deckard -r ./config/environment -l

          Options:
        BANNER
        opt :require, "Ruby file to require first (usually config/environment)", type: :string
        opt :dump, "Dump the result of a Ruby expression, or run a dump script file", type: :string
        opt :load, "Load a deckard stream from standard input"
        opt :output, "Atomically write the dump stream to FILE instead of stdout", type: :string, short: "o"
        opt :output_fd, "Write the dump stream to an inherited file descriptor (3 or higher)", type: :integer
      end

      unless !options[:dump].nil? ^ options[:load]
        Optimist.die "exactly one of -d or -l is required"
      end
      if options[:output] && options[:output_fd]
        Optimist.die "--output and --output-fd are mutually exclusive"
      end
      if options[:load] && (options[:output] || options[:output_fd])
        Optimist.die "--output and --output-fd are only valid with --dump"
      end
      if options[:output_fd] && options[:output_fd] < 3
        Optimist.die "--output-fd must be 3 or higher"
      end
      options
    end

    def dump_command(options)
      counts = with_dump_output(options) { |output| dump(options[:dump], output) }
      Status.report("dumped", counts, @stderr)
    end

    def dump(target, output)
      output.binmode if output.respond_to?(:binmode)
      dumper = Dumper.new(output)

      if File.exist?(target)
        DumpScript.new(dumper).instance_eval(File.read(target), target)
      else
        dumper.dump(eval(target, TOPLEVEL_BINDING.dup, "deckard -d")) # rubocop:disable Security/Eval -- -d takes trusted operator Ruby by design
      end

      dumper.complete
      flush_output(output)
      dumper.counts
    end

    def with_dump_output(options, &block)
      if options[:output]
        with_atomic_file_output(options[:output], &block)
      elsif options[:output_fd]
        with_file_descriptor_output(options[:output_fd], &block)
      else
        yield @stdout
      end
    end

    def with_file_descriptor_output(file_descriptor)
      output = begin
        IO.for_fd(file_descriptor, "wb", autoclose: false)
      rescue ArgumentError, IOError, SystemCallError => e
        raise OutputError,
          "cannot use output file descriptor #{file_descriptor}: #{Deckard.error_detail(e)}",
          cause: e
      end
      yield output
    end

    def with_atomic_file_output(destination)
      validate_output_destination!(destination)
      directory = File.dirname(destination)
      temporary = begin
        Tempfile.new([".deckard-", ".dump"], directory, binmode: true)
      rescue ArgumentError, IOError, SystemCallError => e
        raise OutputError, "cannot create dump output #{destination}: #{Deckard.error_detail(e)}", cause: e
      end

      begin
        result = yield temporary
        begin
          temporary.close
          validate_output_destination!(destination)
          File.rename(temporary.path, destination)
        rescue ArgumentError, IOError, SystemCallError => e
          raise OutputError, "cannot publish dump to #{destination}: #{Deckard.error_detail(e)}", cause: e
        end
        result
      ensure
        temporary.close!
      end
    end

    def validate_output_destination!(destination)
      invalid = File.symlink?(destination) || (File.exist?(destination) && !File.file?(destination))
      return unless invalid

      raise OutputError, "dump output must be a regular file path: #{destination}"
    end

    def flush_output(output)
      output.flush
    rescue Errno::EPIPE
      raise
    rescue IOError, SystemCallError => e
      raise OutputError, "could not flush dump stream: #{Deckard.error_detail(e)}", cause: e
    end

    def load_stream
      @stdin.binmode if @stdin.respond_to?(:binmode)
      loader = Loader.new(@stdin)
      loader.load
      Status.report("loaded", loader.counts, @stderr)
    end
  end
end
