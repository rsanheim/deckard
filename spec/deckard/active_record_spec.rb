# frozen_string_literal: true

require "stringio"
require "uri"
require "active_record"

# These specs run against a real PostgreSQL database - by default a local
# server on port 5433 (libpq defaults fill in the OS user). Point
# DECKARD_TEST_DATABASE_URL elsewhere to override. When no server is
# reachable the whole file is skipped with a pointer.
DECKARD_TEST_DATABASE_URL = ENV.fetch(
  "DECKARD_TEST_DATABASE_URL",
  "postgres://127.0.0.1:5433/deckard_gem_test"
)

deckard_pg_error = nil
begin
  require "pg"
  admin_uri = URI(DECKARD_TEST_DATABASE_URL)
  database = admin_uri.path.delete_prefix("/")
  admin_uri.path = "/postgres"
  admin = PG.connect(admin_uri.to_s)
  if admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [database]).ntuples.zero?
    admin.exec("CREATE DATABASE #{admin.quote_ident(database)}")
  end
  admin.close

  ActiveRecord::Base.establish_connection(DECKARD_TEST_DATABASE_URL)
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define do
    create_table :authors, force: :cascade do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :profiles, force: :cascade do |t|
      t.references :author, null: false
      t.string :bio
    end

    create_table :posts, force: :cascade do |t|
      t.references :author, null: false
      t.string :title, null: false
    end

    create_table :comments, force: :cascade do |t|
      t.references :post, null: false
      t.references :author, null: false
      t.string :body
    end

    create_table :payments, force: :cascade do |t|
      t.references :billable, polymorphic: true
      t.integer :amount
    end

    create_table :cycle_as, force: :cascade do |t|
      t.references :cycle_b
    end

    create_table :cycle_bs, force: :cascade do |t|
      t.references :cycle_a
    end
  end
rescue => e
  deckard_pg_error = "#{e.class}: #{e.message}"
end

unless deckard_pg_error
  class Author < ActiveRecord::Base
    has_one :profile
    has_many :posts

    # Both guards prove the loader's bypass: any load that runs them fails.
    before_save { self.class.callbacks_fired << name }
    validate { errors.add(:base, "always invalid") }

    def self.callbacks_fired
      @callbacks_fired ||= []
    end
  end

  class Profile < ActiveRecord::Base
    belongs_to :author
  end

  class Post < ActiveRecord::Base
    belongs_to :author
    has_many :comments
  end

  class Comment < ActiveRecord::Base
    belongs_to :post
    belongs_to :author
  end

  class Payment < ActiveRecord::Base
    belongs_to :billable, polymorphic: true, optional: true
  end

  class CycleA < ActiveRecord::Base
    belongs_to :cycle_b, optional: true
  end

  class CycleB < ActiveRecord::Base
    belongs_to :cycle_a, optional: true
  end
end

RSpec.describe Deckard::ActiveRecord, skip: deckard_pg_error && <<~MSG do
  PostgreSQL unavailable at #{DECKARD_TEST_DATABASE_URL} (#{deckard_pg_error}).
  Start a local server there or set DECKARD_TEST_DATABASE_URL.
MSG

  before do
    tables = %w[comments payments profiles posts authors cycle_as cycle_bs]
    ActiveRecord::Base.connection.execute("TRUNCATE #{tables.join(", ")} RESTART IDENTITY")
    Author.callbacks_fired.clear
  end

  def create_author(name)
    author = Author.new(name: name)
    author.save!(validate: false)
    author
  end

  def stream(objects)
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    Array(objects).each { |object| dumper.dump(object) }
    dumper.complete
    io.rewind
    [io, dumper]
  end

  it "round trips a graph with destination-generated keys and remapped foreign keys" do
    author = create_author("Rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    comment = Comment.create!(post: post, author: author, body: "I am the business.")

    io, dumper = stream(comment)
    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Comment" => 1)

    Deckard::Loader.new(io).load

    new_author = Author.where.not(id: author.id).sole
    new_post = Post.where.not(id: post.id).sole
    new_comment = Comment.where.not(id: comment.id).sole
    expect(new_author.name).to eq("Rachael")
    expect(new_post.author_id).to eq(new_author.id)
    expect(new_comment.post_id).to eq(new_post.id)
    expect(new_comment.author_id).to eq(new_author.id)
  end

  it "dumps has_one dependents automatically but not has_many collections" do
    author = create_author("Rachael")
    Profile.create!(author: author, bio: "More human than human")
    Post.create!(author: author, title: "not dumped")

    _, dumper = stream(author)

    expect(dumper.counts).to eq("Author" => 1, "Profile" => 1)
  end

  it "dumps a shared dependency once and maps all foreign keys to one destination row" do
    author = create_author("Rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    2.times { |i| Comment.create!(post: post, author: author, body: "comment #{i}") }

    io, dumper = stream(Comment.all)
    expect(dumper.counts["Author"]).to eq(1)

    Deckard::Loader.new(io).load

    new_comments = Comment.where.not(post_id: post.id)
    expect(new_comments.map(&:author_id).uniq).to eq([Author.where.not(id: author.id).sole.id])
  end

  it "leaves a nil belongs_to foreign key nil" do
    Payment.create!(amount: 10)

    io, _ = stream(Payment.all)
    Deckard::Loader.new(io).load

    expect(Payment.count).to eq(2)
    expect(Payment.pluck(:billable_id).uniq).to eq([nil])
  end

  it "bypasses validations and callbacks on load" do
    author = create_author("Rachael")
    io, _ = stream(author)
    Author.callbacks_fired.clear

    Deckard::Loader.new(io).load

    expect(Author.count).to eq(2)
    expect(Author.callbacks_fired).to be_empty
  end

  it "rolls back everything when the stream has no end marker" do
    author = create_author("Rachael")
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    dumper.dump(author)
    io.rewind

    expect { Deckard::Loader.new(io).load }.to raise_error(Deckard::InvalidStream)
    expect(Author.count).to eq(1)
  end

  it "rolls back prior inserts when a later insert fails, raising InsertError with context" do
    io = StringIO.new
    Marshal.dump(Deckard::STREAM_HEADER, io)
    Marshal.dump(["Author", 1, {"name" => "loads fine"}], io)
    Marshal.dump(["Author", 2, {"name" => nil}], io)
    Marshal.dump(Deckard::STREAM_END, io)
    io.rewind

    expect { Deckard::Loader.new(io).load }.to raise_error(Deckard::InsertError, /Author source_id=2 could not be inserted/)
    expect(Author.count).to eq(0)
  end

  it "raises UnsupportedAssociation for a populated polymorphic belongs_to" do
    author = create_author("Rachael")
    payment = Payment.create!(billable: author, amount: 10)

    expect { stream(payment) }.to raise_error(
      Deckard::UnsupportedAssociation,
      "Payment(#{payment.id}).billable is a polymorphic belongs_to association"
    )
  end

  it "raises DumpError on a belongs_to dependency cycle" do
    a = CycleA.create!
    b = CycleB.create!(cycle_a: a)
    a.update_columns(cycle_b_id: b.id)

    expect { stream(a.reload) }.to raise_error(Deckard::DumpError, /dependency cycle/)
  end
end
