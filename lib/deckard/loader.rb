# frozen_string_literal: true

module Deckard
  # Reads a Deckard stream incrementally from an input IO, resolving
  # [:id, type, source_id] reference tuples through the source-to-destination
  # ID map and handing each replicant to its class's load_replicant.
  class Loader
    attr_reader :counts

    # An optional block is called with the running counts after every
    # loaded replicant; the CLI uses it for a progress line.
    def initialize(input, &after_load)
      @input = input
      @after_load = after_load
      @id_map = {}
      @counts = Hash.new(0)
    end

    def load
      with_transaction do
        header = read_frame
        unless header == STREAM_HEADER
          raise InvalidStream, "invalid stream header (expected #{STREAM_HEADER.inspect})"
        end

        loop do
          frame = read_frame
          break if frame == STREAM_END
          load_replicant(frame)
        end
      end
    end

    private

    # The whole load runs in one destination transaction, committing only
    # after a valid end marker. Without a database connection (custom-object
    # streams outside a booted app) the load runs bare.
    def with_transaction(&block)
      return yield unless defined?(::ActiveRecord::Base)

      begin
        ::ActiveRecord::Base.connection_pool
      rescue ::ActiveRecord::ConnectionNotEstablished
        return yield
      end
      ::ActiveRecord::Base.transaction(&block)
    end

    def read_frame
      Marshal.load(@input)
    rescue EOFError
      raise InvalidStream, "stream ended without an end marker"
    rescue TypeError, ArgumentError => e
      raise InvalidStream, "corrupt stream frame: #{e.message}"
    end

    def load_replicant(frame)
      unless frame.is_a?(Array) && frame.size == 3 && frame[0].is_a?(String) && frame[2].is_a?(Hash)
        raise InvalidStream, "malformed stream frame (expected [type, id, attributes] tuple)"
      end

      type, source_id, attributes = frame
      resolved = resolve_references(type, source_id, attributes)
      destination_id, _object = replicant_class(type).load_replicant(type, source_id, resolved)
      @id_map[[type, source_id]] = destination_id
      @counts[type] += 1
      @after_load&.call(@counts)
    end

    def resolve_references(type, source_id, attributes)
      attributes.each_with_object({}) do |(name, value), resolved|
        resolved[name] = reference?(value) ? resolve_reference(type, source_id, name, value) : value
      end
    end

    def reference?(value)
      value.is_a?(Array) && value.size == 3 && value[0] == :id
    end

    def resolve_reference(type, source_id, name, reference)
      _, ref_type, ref_id = reference
      @id_map.fetch([ref_type, ref_id]) do
        raise UnresolvedReference,
          "#{type}(#{source_id}).#{name} references #{ref_type}(#{ref_id}), which has not been loaded"
      end
    end

    def replicant_class(type)
      klass = begin
        Object.const_get(type)
      rescue NameError
        raise LoadError, "cannot load #{type}: class is not defined"
      end

      unless klass.respond_to?(:load_replicant)
        raise LoadError, "cannot load #{type}: #{klass} does not implement load_replicant"
      end
      klass
    end
  end
end
