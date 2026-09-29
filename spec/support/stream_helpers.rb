# frozen_string_literal: true

require "stringio"

# Dump into memory and read the frames back, for specs that look at the
# stream itself.
module StreamHelpers
  def stream(objects)
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    dumper.dump(objects)
    dumper.complete
    io.rewind
    [io, dumper]
  end

  # Every replicant tuple, header and end marker left out.
  def frames(io)
    io.rewind
    result = []
    while (frame = Marshal.load(io)) != Deckard::STREAM_END
      result << frame unless frame == Deckard::STREAM_HEADER
    end
    io.rewind
    result
  end
end
