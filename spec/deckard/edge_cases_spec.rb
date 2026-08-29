# frozen_string_literal: true

require "securerandom"
require "stringio"
require_relative "../support/test_database"
require_relative "../support/test_models"

# Coverage of the ActiveRecord shapes spec section 13 supports (and the ones
# it requires to fail clearly), beyond the conventional models used elsewhere.
RSpec.describe "ActiveRecord edge cases" do
  before do
    if (error = DeckardTestDatabase.setup)
      skip "PostgreSQL unavailable at #{DeckardTestDatabase::URL} (#{error}). " \
        "Start a server there or set DECKARD_TEST_DATABASE_URL."
    end
    DeckardTestDatabase.truncate
  end

  def stream(objects, options = {})
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    Array(objects).each { |object| dumper.dump(object, options) }
    dumper.complete
    io.rewind
    [io, dumper]
  end

  def uuid_pattern
    /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  end

  it "remaps database-generated UUID primary keys" do
    ship = Ship.create!(name: "Off-world shuttle")
    cargo = Cargo.create!(ship: ship, contents: "memories")

    io, _ = stream(cargo)
    Deckard::Loader.new(io).load

    new_ship = Ship.where.not(id: ship.id).sole
    new_cargo = Cargo.where.not(id: cargo.id).sole
    expect(new_ship.id).to match(uuid_pattern)
    expect(new_ship.id).not_to eq(ship.id)
    expect(new_cargo.ship_id).to eq(new_ship.id)
  end

  it "follows a self-referential belongs_to chain with class_name and custom foreign key" do
    boss = Employee.create!(name: "Bryant")
    middle = Employee.create!(name: "Gaff", manager: boss)
    worker = Employee.create!(name: "Deckard", manager: middle)

    io, dumper = stream(worker)
    expect(dumper.counts).to eq("Employee" => 3)

    Deckard::Loader.new(io).load

    new_worker = Employee.where.not(id: [boss.id, middle.id, worker.id]).find_by(name: "Deckard")
    expect(new_worker.manager.name).to eq("Gaff")
    expect(new_worker.manager.manager.name).to eq("Bryant")
    expect(new_worker.manager.manager.manager).to be_nil
  end

  it "dumps a record first when its parent's configured collection points back at it" do
    # Book -> Library (belongs_to) -> books (configured has_many) -> Book
    # again is a diamond, not a cycle: the library still precedes the book.
    library = SpecialLibrary.create!(name: "Tyrell private stacks")
    book = Book.create!(library: library, title: "Owl schematics")
    other = Book.create!(library: library, title: "Nexus specs")

    io, dumper = stream(book)
    expect(dumper.counts).to eq("SpecialLibrary" => 1, "Book" => 2)

    Deckard::Loader.new(io).load

    new_library = SpecialLibrary.where.not(id: library.id).sole
    expect(new_library.books.pluck(:title)).to match_array(["Owl schematics", "Nexus specs"])
    expect(Book.where.not(id: [book.id, other.id]).pluck(:library_id).uniq).to eq([new_library.id])
  end

  it "references an STI subclass by its actual class in the stream" do
    library = SpecialLibrary.create!(name: "Tyrell private stacks")
    book = Book.create!(library: library, title: "Owl schematics")

    io, _ = stream(book, omit: [:books])

    io.rewind
    frames = []
    while (frame = Marshal.load(io)) != Deckard::STREAM_END
      frames << frame unless frame == Deckard::STREAM_HEADER
    end
    expect(frames.map(&:first)).to eq(%w[SpecialLibrary Book])
    book_frame = frames.last
    expect(book_frame[2]["library_id"]).to eq([:id, "SpecialLibrary", library.id])
  end

  it "round trips jsonb, array, decimal, boolean, date, microsecond time, binary, uuid, and enum values" do
    source = Artifact.create!(
      name: "esper photograph",
      meta: {"zoom" => 34, "enhance" => [224, 176]},
      tags: %w[replicant nexus6],
      price: BigDecimal("19.99"),
      active: false,
      released_on: Date.new(2019, 11, 1),
      measured_at: Time.utc(2019, 11, 1, 12, 30, 45, 123_456),
      blob: "\x00\xFF\x01deckard".b,
      token: SecureRandom.uuid,
      status: "live"
    )

    io, _ = stream(source)
    Deckard::Loader.new(io).load

    loaded = Artifact.where.not(id: source.id).sole
    expect(loaded.meta).to eq("zoom" => 34, "enhance" => [224, 176])
    expect(loaded.tags).to eq(%w[replicant nexus6])
    expect(loaded.price).to eq(BigDecimal("19.99"))
    expect(loaded.active).to be(false)
    expect(loaded.released_on).to eq(Date.new(2019, 11, 1))
    expect(loaded.measured_at).to eq(Time.utc(2019, 11, 1, 12, 30, 45, 123_456))
    expect(loaded.blob).to eq("\x00\xFF\x01deckard".b)
    expect(loaded.token).to eq(source.token)
    expect(loaded.status).to eq("live")
  end

  it "raises a clear error dumping a composite primary key model" do
    itinerary = Itinerary.create!(vehicle_id: 1, leg: 1, note: "spinner to the Bradbury")

    expect { stream(itinerary) }
      .to raise_error(Deckard::DumpError, /Itinerary has a composite primary key/)
  end

  it "raises a clear error loading into a composite primary key model" do
    io = StringIO.new
    Marshal.dump(Deckard::STREAM_HEADER, io)
    Marshal.dump(["Itinerary", 1, {"vehicle_id" => 1, "leg" => 1, "note" => "smuggled"}], io)
    Marshal.dump(Deckard::STREAM_END, io)
    io.rewind

    expect { Deckard::Loader.new(io).load }
      .to raise_error(Deckard::LoadError, /Itinerary has a composite primary key/)
    expect(Itinerary.count).to eq(0)
  end
end
