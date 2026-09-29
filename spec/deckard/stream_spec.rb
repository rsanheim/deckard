# frozen_string_literal: true

require "stringio"

# Plain-Ruby fixtures implementing the custom-object replicant protocol.
# Each class keeps a destination-side store and ID counter so loads are
# observable without a database.
class FakeAuthor
  class << self
    attr_accessor :store, :next_id
  end

  def self.reset
    self.store = {}
    self.next_id = 1000
  end

  attr_reader :id
  attr_accessor :name

  def initialize(id:, name:)
    @id = id
    @name = name
  end

  def dump_replicant(dumper)
    dumper.write(self.class, id, {"name" => name})
  end

  def self.load_replicant(type, source_id, attributes, natural_key)
    author = new(id: next_id, name: attributes["name"])
    self.next_id += 1
    store[author.id] = author
    [author.id, author]
  end
end

class FakePost
  class << self
    attr_accessor :store, :next_id
  end

  def self.reset
    self.store = {}
    self.next_id = 5000
  end

  attr_reader :id
  attr_accessor :title, :author, :author_id

  def initialize(id:, title:, author: nil, author_id: nil)
    @id = id
    @title = title
    @author = author
    @author_id = author_id
  end

  def dump_replicant(dumper)
    dumper.dump(author)
    attributes = {
      "title" => title,
      "author_id" => [:id, FakeAuthor.name, author.id]
    }
    dumper.write(self.class, id, attributes)
  end

  def self.load_replicant(type, source_id, attributes, natural_key)
    post = new(id: next_id, title: attributes["title"], author_id: attributes["author_id"])
    self.next_id += 1
    store[post.id] = post
    [post.id, post]
  end
end

RSpec.describe "Deckard stream" do
  before do
    FakeAuthor.reset
    FakePost.reset
  end

  def dump_to_stream
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    yield dumper
    dumper.complete
    io.rewind
    io
  end

  it "round trips objects, remapping references to destination IDs" do
    author = FakeAuthor.new(id: 1, name: "Rob")
    post = FakePost.new(id: 50, title: "Voight-Kampff notes", author: author)

    io = dump_to_stream { |dumper| dumper.dump(post) }
    Deckard::Loader.new(io).load

    loaded_author = FakeAuthor.store.values.first
    loaded_post = FakePost.store.values.first
    expect(loaded_author.name).to eq("Rob")
    expect(loaded_post.title).to eq("Voight-Kampff notes")
    expect(loaded_post.author_id).to eq(loaded_author.id)
    expect(loaded_author.id).not_to eq(1)
  end

  it "dumps a shared dependency once and resolves both references to one destination object" do
    author = FakeAuthor.new(id: 1, name: "Rob")
    posts = [
      FakePost.new(id: 50, title: "First", author: author),
      FakePost.new(id: 51, title: "Second", author: author)
    ]

    io = dump_to_stream { |dumper| dumper.dump(posts) }
    loader = Deckard::Loader.new(io)
    loader.load

    expect(FakeAuthor.store.size).to eq(1)
    author_ids = FakePost.store.values.map(&:author_id).uniq
    expect(author_ids).to eq([FakeAuthor.store.keys.first])
    expect(loader.counts).to eq("FakeAuthor" => 1, "FakePost" => 2)
  end

  it "does not emit an object dumped twice" do
    author = FakeAuthor.new(id: 1, name: "Rob")

    io = dump_to_stream do |dumper|
      dumper.dump(author)
      dumper.dump(author)
      expect(dumper.counts).to eq("FakeAuthor" => 1)
    end
    Deckard::Loader.new(io).load

    expect(FakeAuthor.store.size).to eq(1)
  end

  it "raises DumpError for objects that do not implement dump_replicant" do
    dumper = Deckard::Dumper.new(StringIO.new)

    expect { dumper.dump(Object.new) }.to raise_error(Deckard::DumpError, /dump_replicant/)
  end

  it "reports an output error when an IO failure has no message" do
    output = Object.new
    output.define_singleton_method(:write) { |*| raise IOError, "" }

    expect { Deckard::Dumper.new(output) }
      .to raise_error(Deckard::OutputError, /\(no message\)/) do |error|
        expect(error.cause).to be_a(IOError)
      end
  end

  it "raises InvalidStream on a truncated stream and loads nothing after the truncation" do
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    dumper.dump(FakeAuthor.new(id: 1, name: "Rob"))
    io.rewind

    expect { Deckard::Loader.new(io).load }
      .to raise_error(Deckard::InvalidStream, /without an end marker/)
  end

  it "raises InvalidStream on a wrong header" do
    io = StringIO.new
    Marshal.dump([:not_deckard, 9], io)
    io.rewind

    expect { Deckard::Loader.new(io).load }
      .to raise_error(Deckard::InvalidStream, /header/)
  end

  it "raises InvalidStream on non-Marshal input" do
    io = StringIO.new("definitely not a marshal stream")

    expect { Deckard::Loader.new(io).load }.to raise_error(Deckard::InvalidStream)
  end

  it "raises UnresolvedReference with context when a reference precedes its object" do
    io = StringIO.new
    Marshal.dump(Deckard::STREAM_HEADER, io)
    Marshal.dump(["FakePost", 50, {"title" => "Orphan", "author_id" => [:id, "FakeAuthor", 1]}, []], io)
    Marshal.dump(Deckard::STREAM_END, io)
    io.rewind

    expect { Deckard::Loader.new(io).load }.to raise_error(
      Deckard::UnresolvedReference,
      "FakePost(50).author_id references FakeAuthor(1), which has not been loaded"
    )
  end

  it "raises LoadError when the streamed type is not a defined class" do
    io = StringIO.new
    Marshal.dump(Deckard::STREAM_HEADER, io)
    Marshal.dump(["NoSuchClass", 1, {}, []], io)
    Marshal.dump(Deckard::STREAM_END, io)
    io.rewind

    expect { Deckard::Loader.new(io).load }
      .to raise_error(Deckard::LoadError, /NoSuchClass.*not defined/)
  end

  it "raises LoadError when the streamed class does not implement load_replicant" do
    io = StringIO.new
    Marshal.dump(Deckard::STREAM_HEADER, io)
    Marshal.dump(["String", 1, {}, []], io)
    Marshal.dump(Deckard::STREAM_END, io)
    io.rewind

    expect { Deckard::Loader.new(io).load }
      .to raise_error(Deckard::LoadError, /String does not implement load_replicant/)
  end

  it "raises InvalidStream on a malformed frame without printing attribute values" do
    io = StringIO.new
    Marshal.dump(Deckard::STREAM_HEADER, io)
    Marshal.dump(["FakeAuthor", 1, "sensitive-not-a-hash", []], io)
    Marshal.dump(Deckard::STREAM_END, io)
    io.rewind

    expect { Deckard::Loader.new(io).load }.to raise_error(Deckard::InvalidStream) do |error|
      expect(error.message).not_to include("sensitive")
    end
  end

  it "tracks dump counts by type" do
    author = FakeAuthor.new(id: 1, name: "Rob")
    post = FakePost.new(id: 50, title: "Counted", author: author)

    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    dumper.dump(post)

    expect(dumper.counts).to eq("FakeAuthor" => 1, "FakePost" => 1)
  end
end
