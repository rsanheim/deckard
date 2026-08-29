# frozen_string_literal: true

module Deckard
  # Writes a versioned Marshal stream of replicant tuples to an output IO.
  # Objects are deduplicated by [type, source_id]: a repeated write is a no-op.
  class Dumper
    attr_reader :counts

    def initialize(output)
      @output = output
      @dumped = Set.new
      @counts = Hash.new(0)
      Marshal.dump(STREAM_HEADER, @output)
    end

    # Dump one object, or each element of an enumerable. The object must
    # implement dump_replicant(dumper, options) and write itself (and any
    # dependencies, first) via #write.
    def dump(object, options = {})
      return if object.nil?

      if object.respond_to?(:dump_replicant)
        object.dump_replicant(self, options)
      elsif object.respond_to?(:each)
        object.each { |item| dump(item, options) }
      else
        raise DumpError, "#{object.class} does not implement dump_replicant"
      end
    end

    # Called by dump_replicant implementations to emit one replicant tuple.
    def write(type, id, attributes, _object)
      type = type.to_s
      return if @dumped.include?([type, id])

      @dumped.add([type, id])
      Marshal.dump([type, id, attributes], @output)
      @counts[type] += 1
    end

    # Write the successful-end marker. A stream without it is treated as
    # truncated and never commits on the destination.
    def complete
      Marshal.dump(STREAM_END, @output)
    end
  end
end
