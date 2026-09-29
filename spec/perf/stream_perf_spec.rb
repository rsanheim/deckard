# frozen_string_literal: true

# Performance tests for the core stream (no database). Excluded from the
# default suite; run with `bundle exec rspec --tag perf spec/perf`.
#
# Fixture classes below implement the custom-object replicant protocol (see
# spec/deckard/stream_spec.rb) but keep load_replicant near-zero-cost so
# these tests measure the dumper/loader stream, not fixture bookkeeping.

class PerfRecord
  attr_reader :id, :payload

  def initialize(id:, payload:)
    @id = id
    @payload = payload
  end

  def dump_replicant(dumper)
    dumper.write(self.class, id, {"payload" => payload})
  end

  # Near-zero work: no store, no object allocation beyond the tuple.
  def self.load_replicant(type, source_id, attributes, natural_key)
    [source_id + 1, nil]
  end
end

class PerfConcurrencyRecord
  attr_reader :id

  def initialize(id:)
    @id = id
  end

  def dump_replicant(dumper)
    dumper.write(self.class, id, {})
  end

  class << self
    attr_accessor :loaded_count, :dumper_done
  end

  def self.load_replicant(type, source_id, attributes, natural_key)
    self.loaded_count += 1
    [source_id + 1, nil]
  end
end

class PerfLargeAttributeRecord
  attr_reader :id, :payload

  def initialize(id:, payload:)
    @id = id
    @payload = payload
  end

  def dump_replicant(dumper)
    dumper.write(self.class, id, {"payload" => payload})
  end

  class << self
    attr_accessor :loaded_payload
  end

  def self.load_replicant(type, source_id, attributes, natural_key)
    self.loaded_payload = attributes["payload"]
    [source_id + 1, nil]
  end
end

RSpec.describe "Deckard stream performance", perf: true do
  it "streams concurrently: the loader processes records while the dumper is still writing" do
    PerfConcurrencyRecord.loaded_count = 0
    PerfConcurrencyRecord.dumper_done = false
    loaded_count_at_dumper_done = nil
    record_count = 5_000

    reader, writer = IO.pipe

    dumper_thread = Thread.new do
      dumper = Deckard::Dumper.new(writer)
      record_count.times { |i| dumper.dump(PerfConcurrencyRecord.new(id: i)) }
      dumper.complete
      loaded_count_at_dumper_done = PerfConcurrencyRecord.loaded_count
      PerfConcurrencyRecord.dumper_done = true
      writer.close
    end

    Deckard::Loader.new(reader).load
    dumper_thread.join
    reader.close

    expect(PerfConcurrencyRecord.loaded_count).to eq(record_count)
    # Prove interleaving: a meaningful chunk of records were loaded before
    # the dumper finished writing, not all of them only after.
    expect(loaded_count_at_dumper_done).to be > (record_count / 4)
  end

  it "memory stays bounded while streaming far more data than the memory budget" do
    # MRI's allocator does not reliably return freed heap pages to the OS, so
    # an absolute RSS ceiling is flaky (this floor is easily 100MB+ even for
    # simple allocation churn on macOS). Instead, compare RSS growth for the
    # same ~200MB of data streamed lazily (records built one at a time, never
    # all alive together) against growth when every record is materialized
    # into an array before dumping. Both runs hit the same allocator noise
    # floor, so the *ratio* between them is a stable, non-flaky signal that
    # streaming avoids holding the full object graph in memory.
    record_count = 2_000
    payload_size = 100 * 1024 # ~100KB per record => ~200MB total

    stream_through_pipe = lambda do |records|
      reader, writer = IO.pipe
      dumper_thread = Thread.new do
        dumper = Deckard::Dumper.new(writer)
        records.each { |record| dumper.dump(record) }
        dumper.complete
        writer.close
      end
      Deckard::Loader.new(reader).load
      dumper_thread.join
      reader.close
    end

    # Each variant runs in its own forked child so both start from an
    # identical fresh baseline - measuring RSS growth in-process is order
    # dependent (the allocator's heap, already grown by an earlier
    # measurement, makes a later measurement look artificially cheap).
    measure_growth_kb_in_fork = lambda do |&block|
      result_reader, result_writer = IO.pipe
      pid = fork do
        result_reader.close
        GC.start
        before = Integer(`ps -o rss= -p #{Process.pid}`)
        block.call
        GC.start
        after = Integer(`ps -o rss= -p #{Process.pid}`)
        result_writer.write(after - before)
        result_writer.close
      end
      result_writer.close
      growth_kb = Integer(result_reader.read)
      result_reader.close
      Process.waitpid(pid)
      growth_kb
    end

    lazy_records = Enumerator.new do |yielder|
      record_count.times { |i| yielder << PerfRecord.new(id: i, payload: "x" * payload_size) }
    end
    streaming_growth_kb = measure_growth_kb_in_fork.call { stream_through_pipe.call(lazy_records) }

    materialized_records = Array.new(record_count) { |i| PerfRecord.new(id: i, payload: "x" * payload_size) }
    materialized_growth_kb = measure_growth_kb_in_fork.call { stream_through_pipe.call(materialized_records) }

    warn "[perf] RSS growth streaming ~#{(record_count * payload_size) / (1024 * 1024)}MB: " \
      "lazy=#{streaming_growth_kb}KB materialized=#{materialized_growth_kb}KB"

    expect(streaming_growth_kb).to be < (materialized_growth_kb * 0.75)
  end

  it "large single attributes round trip" do
    payload = "y" * (20 * 1024 * 1024) # ~20MB
    PerfLargeAttributeRecord.loaded_payload = nil

    reader, writer = IO.pipe

    dumper_thread = Thread.new do
      dumper = Deckard::Dumper.new(writer)
      dumper.dump(PerfLargeAttributeRecord.new(id: 1, payload: payload))
      dumper.complete
      writer.close
    end

    Deckard::Loader.new(reader).load
    dumper_thread.join
    reader.close

    expect(PerfLargeAttributeRecord.loaded_payload).to eq(payload)
  end

  it "throughput baseline" do
    record_count = 50_000

    reader, writer = IO.pipe

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    dumper_thread = Thread.new do
      dumper = Deckard::Dumper.new(writer)
      record_count.times { |i| dumper.dump(PerfRecord.new(id: i, payload: "z")) }
      dumper.complete
      writer.close
    end

    Deckard::Loader.new(reader).load
    dumper_thread.join
    reader.close

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    records_per_sec = record_count / elapsed

    warn "[perf] throughput: #{records_per_sec.round} records/sec (#{record_count} records in #{elapsed.round(3)}s)"
    expect(records_per_sec).to be > 2_000
  end
end
