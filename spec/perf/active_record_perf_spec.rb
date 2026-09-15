# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/forum_models"

# Performance tests for the ActiveRecord replicant path (real PostgreSQL).
# Excluded from the default suite; run with
# `bundle exec rspec --tag perf spec/perf/active_record_perf_spec.rb`.
# Truncation cleaning: a wrapping test transaction would distort the timing
# and RSS numbers these examples measure.
#
# The loader inserts record-by-record via insert_all!/RETURNING plus a
# find() per row (see docs/spec.md 10.1) - "record-by-record insertion is
# acceptable for v1.0" - so load bounds here are deliberately loose.
RSpec.describe "Deckard ActiveRecord performance", perf: true, db: :truncation do
  def create_author(name)
    Author.create!(username: name.downcase, name: name)
  end

  # Inserts post_count posts under author, each with comments_per_post
  # comments, bypassing AR object instantiation for speed. Comment bodies
  # are padded to body_size bytes. Returns nothing; the graph is left in
  # the database for the caller to dump.
  def build_graph(author, post_count:, comments_per_post:, body_size: 1)
    post_rows = Array.new(post_count) { |i| {author_id: author.id, title: "Post #{i}"} }
    post_ids = Post.insert_all!(post_rows, returning: [:id]).rows.flatten

    body = "x" * body_size
    post_ids.each_slice(200) do |batch_ids|
      comment_rows = batch_ids.flat_map do |post_id|
        Array.new(comments_per_post) { {post_id: post_id, author_id: author.id, body: body} }
      end
      Comment.insert_all!(comment_rows)
    end
  end

  def rss_kb
    Integer(`ps -o rss= -p #{Process.pid}`)
  end

  it "dumps and loads a 10k-record graph in reasonable time" do
    author = create_author("Rachael")
    build_graph(author, post_count: 100, comments_per_post: 100)
    record_count = 1 + 100 + 10_000

    io = StringIO.new
    dump_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    dumper = Deckard::Dumper.new(io)
    dumper.dump(Comment.all)
    dumper.complete
    dump_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - dump_started_at

    expect(dumper.counts).to eq("Author" => 1, "Post" => 100, "Comment" => 10_000)
    io.rewind

    load_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Deckard::Loader.new(io).load
    load_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - load_started_at

    warn "[perf] dump: #{dump_elapsed.round(3)}s (#{(record_count / dump_elapsed).round} rows/sec)"
    warn "[perf] load: #{load_elapsed.round(3)}s (#{(record_count / load_elapsed).round} rows/sec)"

    expect(dump_elapsed).to be < 30
    expect(load_elapsed).to be < 120
  end

  it "dump memory stays bounded relative to the identity set, not the data" do
    author = create_author("Rachael")
    body_size = 10 * 1024 # ~10KB per comment body => ~100MB total
    build_graph(author, post_count: 100, comments_per_post: 100, body_size: body_size)
    total_data_kb = (100 * 100 * body_size) / 1024

    null_sink = File.open(File::NULL, "w")

    GC.start
    rss_before = rss_kb

    dumper = Deckard::Dumper.new(null_sink)
    dumper.dump(Comment.all)
    dumper.complete

    GC.start
    rss_after = rss_kb
    null_sink.close

    growth_kb = rss_after - rss_before
    warn "[perf] dump RSS growth streaming ~#{total_data_kb / 1024}MB: #{growth_kb}KB"

    expect(growth_kb).to be < 80_000
  end

  it "the destination ID map is the only load-side growth" do
    author = create_author("Rachael")
    build_graph(author, post_count: 100, comments_per_post: 100)

    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    dumper.dump(Comment.all)
    dumper.complete
    io.rewind

    GC.start
    rss_before = rss_kb

    # Loaded AR objects churn through the transaction (find() per insert),
    # which is noisier than the pure-stream case in stream_perf_spec.rb, so
    # this bound is kept generous to avoid flaking.
    Deckard::Loader.new(io).load

    GC.start
    rss_after = rss_kb

    growth_kb = rss_after - rss_before
    warn "[perf] load RSS growth for 10k records: #{growth_kb}KB"

    expect(growth_kb).to be < 120_000
  end
end
