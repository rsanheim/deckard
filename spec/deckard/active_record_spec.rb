# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/forum_models"

RSpec.describe Deckard::ActiveRecord, :db do
  before do
    Author.callbacks_fired.clear
  end

  def create_author(username, name = username.capitalize)
    Author.create!(username: username, name: name)
  end

  def stream(objects, options = {})
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    Array(objects).each { |object| dumper.dump(object, options) }
    dumper.complete
    io.rewind
    [io, dumper]
  end

  it "copies a belongs_to foreign key that targets a non-primary-key column without remapping it" do
    rachael = create_author("rachael")
    deckard = create_author("deckard")
    post = Post.create!(author: rachael, title: "Nexus-6 field notes")
    comment = Comment.create!(post: post, author: deckard, body: "Have you ever retired a human by mistake?")
    mention = Mention.create!(comment: comment, mentioned_username: "rachael")

    io, dumper = stream(mention)
    expect(dumper.counts).to eq("Author" => 2, "Post" => 1, "Comment" => 1, "Mention" => 1)

    Deckard::Loader.new(io).load

    new_mention = Mention.where.not(id: mention.id).sole
    expect(new_mention.mentioned_username).to eq("rachael")
    expect(new_mention.author).to eq(rachael)
  end

  it "does not reload a belongs_to parent that is already in the stream" do
    author = create_author("rachael")
    ids = 3.times.map { |i| Post.create!(author: author, title: "Post #{i}").id }
    fresh_posts = Post.where(id: ids).order(:id).to_a

    author_queries = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      author_queries += 1 if payload[:sql].include?('"authors"')
    end
    io, dumper = stream(fresh_posts)
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(author_queries).to eq(1)
    expect(dumper.counts).to eq("Author" => 1, "Post" => 3)
    Deckard::Loader.new(io).load
    expect(Post.where(author_id: author.id).count).to eq(6)
  end

  it "round trips a graph with destination-generated keys and remapped foreign keys" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    comment = Comment.create!(post: post, author: author, body: "I am the business.")

    io, dumper = stream(comment)
    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Comment" => 1)

    # Loading into the same database: the author's natural key would match
    # the source row, so change it and force a fresh insert.
    author.update_columns(username: "rachael-source")
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
    author = create_author("rachael")
    Profile.create!(author: author, bio: "More human than human")
    Post.create!(author: author, title: "not dumped")

    _, dumper = stream(author)

    expect(dumper.counts).to eq("Author" => 1, "Profile" => 1)
  end

  it "dumps a shared dependency once and maps all foreign keys to one destination row" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    2.times { |i| Comment.create!(post: post, author: author, body: "comment #{i}") }

    io, dumper = stream(Comment.all)
    expect(dumper.counts["Author"]).to eq(1)

    author.update_columns(username: "rachael-source")
    Deckard::Loader.new(io).load

    new_comments = Comment.where.not(post_id: post.id)
    expect(new_comments.map(&:author_id).uniq).to eq([Author.where.not(id: author.id).sole.id])
  end

  it "leaves a nil belongs_to foreign key nil" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Uncategorized musings")

    io, _ = stream(post)
    Deckard::Loader.new(io).load

    expect(Post.count).to eq(2)
    expect(Post.pluck(:category_id).uniq).to eq([nil])
  end

  it "bypasses validations and callbacks on load" do
    author = Author.new(username: "rachael", name: "Invalid Replicant")
    author.save!(validate: false)
    io, _ = stream(author)
    author.update_columns(username: "rachael-source")
    Author.callbacks_fired.clear

    Deckard::Loader.new(io).load

    expect(Author.count).to eq(2)
    expect(Author.callbacks_fired).to be_empty
  end

  it "rolls back everything when the stream has no end marker" do
    author = create_author("rachael")
    author.update_columns(username: "rachael-source")
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
    Marshal.dump(["Author", 1, {"username" => "fine", "name" => "loads fine"}], io)
    Marshal.dump(["Author", 2, {"username" => "broken", "name" => nil}], io)
    Marshal.dump(Deckard::STREAM_END, io)
    io.rewind

    expect { Deckard::Loader.new(io).load }.to raise_error(Deckard::InsertError, /Author source_id=2 could not be inserted/)
    expect(Author.count).to eq(0)
  end

  it "round trips a populated polymorphic belongs_to" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    reaction = Reaction.create!(author: author, reactable: post, kind: "like")

    io, dumper = stream(reaction)
    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Reaction" => 1)

    Deckard::Loader.new(io).load

    new_post = Post.where.not(id: post.id).sole
    new_reaction = Reaction.where.not(id: reaction.id).sole
    expect(new_reaction.reactable_type).to eq("Post")
    expect(new_reaction.reactable_id).to eq(new_post.id)
  end

  it "round trips an explicitly selected reverse polymorphic has_many" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    reaction = Reaction.create!(author: author, reactable: post, kind: "like")

    io, dumper = stream(author, associations: [:reactions])
    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Reaction" => 1)

    author.update_columns(username: "rachael-source")
    Deckard::Loader.new(io).load

    new_author = Author.where.not(id: author.id).sole
    new_reaction = Reaction.where.not(id: reaction.id).sole
    expect(new_author.reactions).to contain_exactly(new_reaction)
    expect(new_reaction.reactable).to eq(Post.where.not(id: post.id).sole)
  end

  it "omits polymorphic traversal without changing the foreign-key fields" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    reaction = Reaction.create!(author: author, reactable: post, kind: "like")

    io, dumper = stream(reaction, omit_associations: [:reactable])
    expect(dumper.counts).to eq("Author" => 1, "Reaction" => 1)

    Deckard::Loader.new(io).load

    new_reaction = Reaction.where.not(id: reaction.id).sole
    expect(new_reaction.kind).to eq("like")
    expect(new_reaction.reactable_type).to eq("Post")
    expect(new_reaction.reactable_id).to eq(post.id)
  end
end
