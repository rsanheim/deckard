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
      @in_progress = Hash.new(0)
      @counts = Hash.new(0)
      write_frame(STREAM_HEADER)
    end

    # Dump one object, or each element of an enumerable. The object must
    # implement dump_replicant(dumper) and write itself (and any
    # dependencies, first) via #write.
    def dump(object)
      return if object.nil?

      if object.respond_to?(:dump_replicant)
        object.dump_replicant(self)
      elsif object.respond_to?(:find_each)
        object.find_each { |item| dump(item) }
      elsif object.respond_to?(:each)
        object.each { |item| dump(item) }
      else
        raise DumpError, "#{object.class} does not implement dump_replicant"
      end
    end

    # Runs the block for a [type, id] that is not yet written. A record
    # reached again while its dump is in progress higher up the stack (e.g.
    # record -> parent -> parent's collection -> child -> record) is entered
    # a second time so it can be written as soon as its own parents are; the
    # outer call's later write is then a no-op. A third entry can only happen
    # while the second is still walking the record's belongs_to parents,
    # which means those parents lead back to the record: a true cycle. That
    # entry is skipped, and callers that require the identity to be emitted
    # first check #dumped? after and raise.
    def once(type, id)
      key = [type.to_s, id]
      return if @dumped.include?(key) || @in_progress[key] >= 2

      @in_progress[key] += 1
      begin
        yield
      ensure
        @in_progress[key] -= 1
      end
    end

    def dumped?(type, id)
      @dumped.include?([type.to_s, id])
    end

    # Called by dump_replicant implementations to emit one replicant tuple.
    # natural_key names the attributes by which the destination matches an
    # existing record to reuse; empty means always insert.
    def write(type, id, attributes, natural_key = [])
      type = type.to_s
      unless natural_key.is_a?(Array)
        raise DumpError, "#{type}(#{id}): natural key must be an array of attribute names, got #{natural_key.class}"
      end
      return if @dumped.include?([type, id])

      @dumped.add([type, id])
      write_frame([type, id, attributes, natural_key])
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
