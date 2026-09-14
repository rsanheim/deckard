# frozen_string_literal: true

module Deckard
  # Writes a versioned Marshal stream of replicant tuples to an output IO.
  # Objects are deduplicated by [type, source_id]: a repeated write is a no-op.
  class Dumper
    attr_reader :counts

    # An optional block is called with the running counts after every
    # written replicant; the CLI uses it for a progress line.
    def initialize(output, &after_write)
      @output = output
      @after_write = after_write
      @dumped = Set.new
      @in_progress = Set.new
      @counts = Hash.new(0)
      write_frame(STREAM_HEADER)
    end

    # Dump one object, or each element of an enumerable. The object must
    # implement dump_replicant(dumper, options) and write itself (and any
    # dependencies, first) via #write.
    def dump(object, options = {})
      return if object.nil?

      if object.respond_to?(:dump_replicant)
        object.dump_replicant(self, options)
      elsif object.respond_to?(:find_each)
        object.find_each { |item| dump(item, options) }
      elsif object.respond_to?(:each)
        object.each { |item| dump(item, options) }
      else
        raise DumpError, "#{object.class} does not implement dump_replicant"
      end
    end

    # Runs the block once per [type, id]. Skipped when that identity is
    # already written, or when its dump is in progress higher up the stack -
    # a traversal loop (e.g. record -> parent -> parent's collection ->
    # record) that the in-progress caller finishes writing itself. Callers
    # that require the identity to be emitted first check #dumped? after.
    def once(type, id)
      key = [type.to_s, id]
      return if @dumped.include?(key) || @in_progress.include?(key)

      @in_progress.add(key)
      begin
        yield
      ensure
        @in_progress.delete(key)
      end
    end

    def dumped?(type, id)
      @dumped.include?([type.to_s, id])
    end

    # Called by dump_replicant implementations to emit one replicant tuple.
    def write(type, id, attributes, _object)
      type = type.to_s
      return if @dumped.include?([type, id])

      @dumped.add([type, id])
      write_frame([type, id, attributes])
      @counts[type] += 1
      @after_write&.call(@counts)
    end

    # Write the successful-end marker. A stream without it is treated as
    # truncated and never commits on the destination.
    def complete
      write_frame(STREAM_END)
    end

    private

    def write_frame(frame)
      Marshal.dump(frame, @output)
    rescue Errno::EPIPE
      raise
    rescue IOError, SystemCallError => e
      raise OutputError, "could not write dump stream: #{Deckard.error_detail(e)}", cause: e
    end
  end
end
