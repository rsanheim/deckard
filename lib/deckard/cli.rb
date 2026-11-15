# frozen_string_literal: true

require "optimist"
require_relative "plan_report"
require_relative "status"

module Deckard
  # The deckard executable: boots the application in the working directory
  # (or the file given to -r), -d dumps a Ruby expression or dump script to
  # stdout, -l loads a stream from stdin, --plan prints a root model's plan.
  # Required from exe/deckard, not from the library itself.
  class CLI
    # Evaluation context for dump scripts and -d expressions: exposes only
    # dump(object). Scripts see any extra command-line arguments in ARGV.
    class DumpScript
      def initialize(&dumper)
        @dumper = dumper
      end

      def dump(object)
        @dumper.call.dump(object)
      end
    end

    def initialize
      @stdin = $stdin
      @stdout = $stdout
      @stderr = $stderr
    end

    def run(argv)
      options = parse(argv)
      reserve_stdout if options[:dump]
      environment = options[:require]
      environment ||= "config/environment.rb" if File.file?("config/environment.rb")
      require File.expand_path(environment) if environment

      if options[:dump]
        dump(options[:dump], environment_loaded: !environment.nil?)
      elsif options[:plan]
        print_plan(options[:plan], options[:format])
      else
        load_stream(options)
      end
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

            dump:  deckard -d "User.find(1)" > user.dump
            load:  deckard -l < user.dump
            pipe:  ssh example.org "deckard -r /app/config/environment -d 'User.find(1)'" | deckard -l
            plan:  deckard --plan User

          Run from a Rails application's root, deckard loads config/environment.rb.

          Options:
        BANNER
        opt :require, "Ruby file to require instead of config/environment.rb", type: :string
        opt :dump, "Dump the result of a Ruby expression, or run a dump script (a file, or - for stdin)", type: :string
        opt :load, "Load a deckard stream from standard input"
        opt :plan, "Print the plan for dumps rooted at MODEL", type: :string
        opt :format, "Plan output: #{PlanReport::FORMATS.join(" or ")}", default: "text"
        opt :force, "Allow loading into a production environment"
      end

      unless [options[:dump], options[:plan], options[:load] || nil].compact.size == 1
        Optimist.die "exactly one of -d, -l or --plan is required"
      end
      Optimist.die :format, "must be one of #{PlanReport::FORMATS.join(", ")}" unless PlanReport::FORMATS.include?(options[:format])
      options
    end

    # Every replicate block must have run before a plan is read, and Rails
    # only eager loads on its own when config.eager_load is on.
    def eager_load
      Zeitwerk::Loader.eager_load_all if defined?(Zeitwerk::Loader)
    end

    def dump(target, environment_loaded:)
      eager_load
      ModelConfig.validate!
      @stdout.binmode
      # Start the stream on demand so an expression can fail before writing to stdout.
      dumper = nil
      start_dump = -> { dumper ||= Dumper.new(@stdout) { |counts| Status.progress("dumping", counts, @stderr) } }
      script = DumpScript.new(&start_dump)

      if target == "-"
        script.instance_eval(@stdin.read, "<stdin>")
      elsif File.exist?(target)
        script.instance_eval(File.read(target), target)
      else
        result = begin
          script.instance_eval(target, "deckard -d")
        rescue NameError => error
          raise if environment_loaded || !error.instance_of?(NameError)

          raise DumpError, "#{Deckard.error_detail(error)}. Run from a Rails app with config/environment.rb or pass -r FILE."
        end
        script.dump(result)
      end

      dumper = start_dump.call
      dumper.complete
      @stdout.flush
      Status.report("dumped", dumper.counts, @stderr)
    end

    def print_plan(model_name, format)
      eager_load
      klass = model_name.safe_constantize
      raise ConfigurationError, "#{model_name.inspect} is not a loaded ActiveRecord model" unless klass.respond_to?(:replicate)

      plan = ModelConfig.plan_for(klass)
      raise ConfigurationError, "#{klass} has no replicate block" if plan.equal?(ModelConfig::NONE)

      problems = plan.problems
      raise ConfigurationError, problems.join("\n") unless problems.empty?

      @stdout.write PlanReport.render(plan.to_h, format)
    end

    def load_stream(options)
      if Deckard.production_environment? && !options[:force]
        raise LoadError, "refusing to load into a production environment (pass --force to override)"
      end

      @stdin.binmode
      loader = Loader.new(@stdin) { |counts| Status.progress("loading", counts, @stderr) }
      loader.load
      Status.report("loaded", loader.counts, @stderr)
    end
  end
end
