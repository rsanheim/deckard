# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/test_models"

RSpec.describe Deckard::ActiveRecord, :db do
  before do
    Author.callbacks_fired.clear
  end

  def create_author(name)
    Author.create!(name: name)
  end

  def stream(objects, options = {})
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    Array(objects).each { |object| dumper.dump(object, options) }
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
    author = Author.new(name: "Invalid Replicant")
    author.save!(validate: false)
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

  it "round trips a populated polymorphic belongs_to" do
    author = create_author("Rachael")
    payment = Payment.create!(billable: author, amount: 10)

    io, dumper = stream(payment)
    expect(dumper.counts).to eq("Author" => 1, "Payment" => 1)

    Deckard::Loader.new(io).load

    new_author = Author.where.not(id: author.id).sole
    new_payment = Payment.where.not(id: payment.id).sole
    expect(new_payment.billable_type).to eq("Author")
    expect(new_payment.billable_id).to eq(new_author.id)
  end

  it "round trips an explicitly selected reverse polymorphic has_many" do
    author = create_author("Rachael")
    payment = Payment.create!(billable: author, amount: 10)

    io, dumper = stream(author, associations: [:payments])
    expect(dumper.counts).to eq("Author" => 1, "Payment" => 1)

    Deckard::Loader.new(io).load

    new_author = Author.where.not(id: author.id).sole
    new_payment = Payment.where.not(id: payment.id).sole
    expect(new_author.payments).to contain_exactly(new_payment)
  end

  it "omits polymorphic traversal without changing the foreign-key fields" do
    author = create_author("Rachael")
    payment = Payment.create!(billable: author, amount: 10)

    io, dumper = stream(payment, omit_associations: [:billable])
    expect(dumper.counts).to eq("Payment" => 1)

    Deckard::Loader.new(io).load

    new_payment = Payment.where.not(id: payment.id).sole
    expect(new_payment.amount).to eq(10)
    expect(new_payment.billable_type).to eq("Author")
    expect(new_payment.billable_id).to eq(author.id)
  end

  it "raises DumpError on a belongs_to dependency cycle" do
    a = CycleA.create!
    b = CycleB.create!(cycle_a: a)
    a.update_columns(cycle_b_id: b.id)

    expect { stream(a.reload) }.to raise_error(Deckard::DumpError, /dependency cycle/)
  end
end
