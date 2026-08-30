# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/test_models"

RSpec.describe "replicate model DSL", :db do
  def stream(objects, options = {})
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    Array(objects).each { |object| dumper.dump(object, options) }
    dumper.complete
    io.rewind
    [io, dumper]
  end

  def frames(io)
    io.rewind
    result = []
    loop do
      frame = Marshal.load(io)
      break if frame == Deckard::STREAM_END
      result << frame unless frame == Deckard::STREAM_HEADER
    end
    result
  end

  it "dumps has_many associations configured in the replicate block" do
    library = Library.create!(name: "LAPD archive", secret: "s3krit")
    2.times { |i| Book.create!(library: library, title: "Case file #{i}") }

    io, dumper = stream(library)
    expect(dumper.counts).to eq("Library" => 1, "Book" => 2)

    Deckard::Loader.new(io).load
    new_library = Library.where.not(id: library.id).sole
    expect(new_library.books.count).to eq(2)
  end

  it "omits attributes configured in the replicate block" do
    library = Library.create!(name: "LAPD archive", secret: "s3krit")

    io, _ = stream(library)

    library_frame = frames(io).find { |type, _, _| type == "Library" }
    expect(library_frame[2]).not_to have_key("secret")

    io.rewind
    Deckard::Loader.new(io).load
    expect(Library.where.not(id: library.id).sole.secret).to be_nil
  end

  it "inherits replicate configuration in subclasses" do
    library = SpecialLibrary.create!(name: "Tyrell private stacks", secret: "s3krit")
    Book.create!(library: library, title: "Owl schematics")

    io, dumper = stream(library)
    expect(dumper.counts).to eq("SpecialLibrary" => 1, "Book" => 1)

    Deckard::Loader.new(io).load
    expect(SpecialLibrary.where.not(id: library.id).sole.books.sole.title).to eq("Owl schematics")
  end

  it "raises DumpError when a replicate block names a missing association" do
    broken = MisconfiguredLibrary.create!(name: "broken")

    expect { stream(broken) }.to raise_error(Deckard::DumpError, /branches/)
  end

  it "includes per-dump associations, skipping classes that lack them" do
    author = Author.new(name: "Rachael")
    author.save!(validate: false)
    Profile.create!(author: author, bio: "More human than human")
    Post.create!(author: author, title: "Nexus-6 field notes")

    # :posts cascades to Profile too, which has no such association - that
    # must be skipped, not raised.
    _, dumper = stream(author, associations: [:posts])

    expect(dumper.counts).to eq("Author" => 1, "Profile" => 1, "Post" => 1)
  end

  it "applies per-dump omissions to attributes and associations" do
    author = Author.new(name: "Rachael")
    author.save!(validate: false)
    Profile.create!(author: author, bio: "unused")

    io, dumper = stream(author, omit: [:created_at, :profile])

    expect(dumper.counts).to eq("Author" => 1)
    expect(frames(io).first[2]).not_to have_key("created_at")
  end

  it "omitting a belongs_to by association name or foreign key drops traversal and the key" do
    library = Library.create!(name: "LAPD archive")
    book = Book.create!(library: library, title: "Case file")

    [{omit: [:library]}, {omit: [:library_id]}].each do |options|
      io, dumper = stream(book, options)
      expect(dumper.counts).to eq("Book" => 1)
      expect(frames(io).first[2]).not_to have_key("library_id")

      io.rewind
      Deckard::Loader.new(io).load
    end

    expect(Book.where.not(id: book.id).pluck(:library_id)).to eq([nil, nil])
  end

  it "reuses and updates an existing destination record matched by natural key" do
    source_reader = Reader.create!(login: "rob", email: "rob@source.example")
    ReaderEmail.create!(reader: source_reader, email: "rob@shared.example", label: "from-source")
    io, _ = stream(ReaderEmail.all)

    DeckardTestDatabase.truncate
    existing = Reader.create!(login: "rob", email: "rob@dest.example")
    ReaderEmail.create!(reader: existing, email: "rob@shared.example", label: "stale")

    Reader.callbacks_fired.clear
    Deckard::Loader.new(io).load

    expect(Reader.callbacks_fired).to be_empty
    expect(Reader.sole.id).to eq(existing.id)
    expect(Reader.sole.email).to eq("rob@source.example")
    email = ReaderEmail.sole
    expect(email.reader_id).to eq(existing.id)
    expect(email.label).to eq("from-source")
  end

  it "creates a new record when the natural key matches nothing" do
    Reader.create!(login: "rob", email: "rob@source.example")
    io, _ = stream(Reader.all)

    DeckardTestDatabase.truncate
    Deckard::Loader.new(io).load

    expect(Reader.sole.login).to eq("rob")
  end

  it "fails and rolls back when the natural key is ambiguous" do
    Reader.create!(login: "rob", email: "rob@source.example")
    io, _ = stream(Reader.all)

    DeckardTestDatabase.truncate
    Reader.create!(login: "rob", email: "first@dest.example")
    Reader.create!(login: "rob", email: "second@dest.example")

    expect { Deckard::Loader.new(io).load }
      .to raise_error(Deckard::LoadError, /natural key \(login\) matches more than one/)
    expect(Reader.pluck(:email)).to match_array(["first@dest.example", "second@dest.example"])
  end
end
