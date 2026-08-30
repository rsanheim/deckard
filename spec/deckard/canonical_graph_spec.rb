# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/test_models"

RSpec.describe "canonical ActiveRecord graph", db: :truncation do
  before do
    Author.callbacks_fired.clear
  end

  def create_author(name)
    author = Author.new(name: name)
    author.save!(validate: false)
    author
  end

  def create_source_author
    author = create_author("Jane Doe")
    author.create_profile!(bio: "Writer and editor")

    first_post = author.posts.create!(title: "Draft previews fail to render")
    first_post.comments.create!(author: author, body: "Only fails with embedded images")
    first_post.comments.create!(author: author, body: "Started after the last deploy")

    second_post = author.posts.create!(title: "Welcome to my archive")
    second_post.comments.create!(author: author, body: "Pinned introduction")

    author
  end

  def dump(author)
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    dumper.dump(author, associations: %i[posts comments])
    dumper.complete
    io.rewind
    [io, dumper]
  end

  def replicated_attributes(record)
    foreign_keys = record.class.reflect_on_all_associations(:belongs_to).map(&:foreign_key)
    record.attributes.except(record.class.primary_key, *foreign_keys)
  end

  def author_snapshot(author)
    {
      attributes: replicated_attributes(author),
      profile: replicated_attributes(author.profile),
      posts: author.posts.order(:title).map do |post|
        {
          attributes: replicated_attributes(post),
          comments: post.comments.order(:body).map { |comment| replicated_attributes(comment) }
        }
      end
    }
  end

  def aggregate_ids(author)
    {
      "Author" => [author.id],
      "Profile" => [author.profile.id],
      "Post" => author.posts.ids,
      "Comment" => author.posts.flat_map { |post| post.comments.ids }
    }
  end

  def aggregate_counts(author)
    aggregate_ids(author).transform_values(&:size)
  end

  def advance_destination_sequences
    [Author, Profile, Post, Comment].each do |model|
      connection = model.connection
      sequence = connection.default_sequence_name(model.table_name, model.primary_key)
      connection.execute("ALTER SEQUENCE #{connection.quote_table_name(sequence)} RESTART WITH 100000")
    end
  end

  def expect_local_keys(author)
    expect(author.profile.author_id).to eq(author.id)
    expect(author.posts).not_to be_empty

    author.posts.each do |post|
      expect(post.author_id).to eq(author.id)
      expect(post.comments).not_to be_empty
      post.comments.each do |comment|
        expect(comment.author_id).to eq(author.id)
        expect(comment.post_id).to eq(post.id)
      end
    end
  end

  it "clones an author's complete support dataset into another database" do
    DeckardTestDatabase.setup_destination

    source_author = create_source_author
    source_snapshot = author_snapshot(source_author)
    source_ids = aggregate_ids(source_author)
    stream, dumper = dump(source_author)

    expect(dumper.counts).to eq(aggregate_counts(source_author))

    DeckardTestDatabase.with_destination do
      DeckardTestDatabase.truncate
      begin
        advance_destination_sequences

        loader = Deckard::Loader.new(stream)
        loader.load

        cloned_author = Author.find_by!(name: "Jane Doe")
        expect(author_snapshot(cloned_author)).to eq(source_snapshot)
        expect(aggregate_counts(cloned_author)).to eq(dumper.counts)
        expect(loader.counts).to eq(dumper.counts)

        loader.counts.each do |type, count|
          expect(Object.const_get(type).count).to eq(count)
        end

        expect_local_keys(cloned_author)
        aggregate_ids(cloned_author).each do |type, ids|
          expect(ids & source_ids.fetch(type)).to be_empty
        end
      ensure
        DeckardTestDatabase.truncate
      end
    end
  end
end
