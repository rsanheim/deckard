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
    author = Author.create!(name: "Rachael")
    Profile.create!(author: author, bio: "More human than human")
    Post.create!(author: author, title: "Nexus-6 field notes")

    # :posts cascades to Profile too, which has no such association - that
    # must be skipped, not raised.
    _, dumper = stream(author, associations: [:posts])

    expect(dumper.counts).to eq("Author" => 1, "Profile" => 1, "Post" => 1)
  end

  it "applies per-dump field and association omissions independently" do
    author = Author.create!(name: "Rachael")
    Profile.create!(author: author, bio: "unused")

    io, dumper = stream(author, omit_fields: [:created_at], omit_associations: [:profile])

    expect(dumper.counts).to eq("Author" => 1)
    expect(frames(io).first[2]).not_to have_key("created_at")
  end

  it "omitting a belongs_to association skips traversal but preserves its foreign key" do
    library = Library.create!(name: "LAPD archive")
    book = Book.create!(library: library, title: "Case file")

    io, dumper = stream(book, omit_associations: [:library])
    expect(dumper.counts).to eq("Book" => 1)

    Deckard::Loader.new(io).load

    expect(Book.where.not(id: book.id).sole.library_id).to eq(library.id)
  end

  it "omitting a foreign-key field still traverses the association" do
    library = Library.create!(name: "LAPD archive")
    book = Book.create!(library: library, title: "Case file")

    io, dumper = stream(book, omit_fields: [:library_id])
    expect(dumper.counts).to eq("Library" => 1, "Book" => 1)
    expect(frames(io).last[2]).not_to have_key("library_id")

    io.rewind
    Deckard::Loader.new(io).load

    expect(Book.where.not(id: book.id).sole.library_id).to be_nil
  end

  it "remaps a configured scalar reference to the target's destination ID" do
    library = Library.create!(name: "Archive")
    related = Book.create!(library: library, title: "Reference volume")
    book = Book.create!(library: library, title: "Index", related_book_id: related.id)

    io, dumper = stream(book)
    book_frames = frames(io).select { |type, _, _| type == "Book" }

    expect(dumper.counts).to eq("Library" => 1, "Book" => 2)
    expect(book_frames.map { |_, id, _| id }).to eq([related.id, book.id])
    expect(book_frames.last[2]["related_book_id"]).to eq([:id, "Book", related.id])

    io.rewind
    Deckard::Loader.new(io).load

    cloned_related = Book.where(title: related.title).where.not(id: related.id).sole
    cloned_book = Book.where(title: book.title).where.not(id: book.id).sole
    expect(cloned_book.related_book_id).to eq(cloned_related.id)
    expect(cloned_book.related_book_id).not_to eq(related.id)
  end

  it "uses a scalar reference resolver block" do
    library = Library.create!(name: "Archive")
    related = Book.create!(library: library, title: "Reference volume")
    book = Book.create!(library: library, title: "Index", resolved_book_id: related.id)

    io, _ = stream(book)
    owner_frame = frames(io).find { |type, id, _| type == "Book" && id == book.id }
    expect(owner_frame[2]["resolved_book_id"]).to eq([:id, "Book", related.id])

    io.rewind
    Deckard::Loader.new(io).load
    cloned_related = Book.where(title: related.title).where.not(id: related.id).sole
    cloned_book = Book.where(title: book.title).where.not(id: book.id).sole
    expect(cloned_book.resolved_book_id).to eq(cloned_related.id)
  end

  it "leaves nil scalar references nil without traversing another record" do
    book = Book.create!(title: "Standalone")

    io, dumper = stream(book)

    expect(dumper.counts).to eq("Book" => 1)
    expect(frames(io).sole[2]["related_book_id"]).to be_nil
  end

  it "skips traversal when a scalar reference field is omitted" do
    related = Book.create!(title: "Reference volume")
    book = Book.create!(title: "Index", related_book_id: related.id)

    io, dumper = stream(book, omit_fields: [:related_book_id])

    expect(dumper.counts).to eq("Book" => 1)
    expect(frames(io).sole[2]).not_to have_key("related_book_id")
  end

  it "fails rather than preserving an unresolved scalar source ID" do
    book = Book.create!(title: "Broken index", related_book_id: 999_999)

    expect { stream(book) }
      .to raise_error(Deckard::DumpError, /related_book_id scalar reference did not resolve/)
  end

  it "preserves the intended error and cause when a scalar resolver has no message" do
    book = BrokenReferenceBook.create!(title: "Broken resolver", resolved_book_id: 1)

    expect { stream(book) }.to raise_error(Deckard::DumpError, /RuntimeError: \(no message\)/) do |error|
      expect(error.cause).to be_a(RuntimeError)
    end
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
