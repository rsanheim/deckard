# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/forum_models"

# The app-developer view: seed a realistic forum, dump one root object, load
# it into a second database, and check the clone from the outside.
RSpec.describe "canonical forum graph", db: :multiple do
  before do
    DeckardTestDatabase::Tasks.load_seed
  end

  def replicated_attributes(record)
    foreign_keys = record.class.reflect_on_all_associations(:belongs_to).map(&:foreign_key)
    record.attributes.except(record.class.primary_key, *foreign_keys)
  end

  def comment_snapshot(comment)
    {
      attributes: replicated_attributes(comment),
      author: comment.author.username,
      replies: comment.replies.order(:body).map { |reply| comment_snapshot(reply) }
    }
  end

  def post_snapshot(post)
    {
      attributes: replicated_attributes(post),
      author: post.author.username,
      category: post.category&.slug,
      comments: post.comments.where(parent_id: nil).order(:body).map { |comment| comment_snapshot(comment) }
    }
  end

  def author_snapshot(author)
    {
      attributes: replicated_attributes(author),
      profile: replicated_attributes(author.profile),
      emails: author.author_emails.order(:address).map { |email| replicated_attributes(email) },
      attachments: author.attachments.order(:filename).map do |attachment|
        {
          attributes: replicated_attributes(attachment),
          variants: attachment.variants.order(:variant).map { |variant| replicated_attributes(variant) }
        }
      end,
      posts: author.posts.order(:title).map { |post| post_snapshot(post) }
    }
  end

  def advance_destination_sequences
    [Author, Profile, Post, Comment].each do |model|
      connection = model.connection
      sequence = connection.default_sequence_name(model.table_name, model.primary_key)
      connection.execute("ALTER SEQUENCE #{connection.quote_table_name(sequence)} RESTART WITH 100000")
    end
  end

  it "clones a post and its comment threads into another database" do
    source_post = Post.find_by!(title: "Nexus-6 field notes")
    source_snapshot = post_snapshot(source_post)
    source_ids = {"Author" => Author.ids, "Post" => Post.ids, "Comment" => Comment.ids}
    stream, dumper = stream(source_post)

    expect(dumper.counts).to eq("Author" => 3, "Category" => 1, "Post" => 1, "Comment" => 4, "Mention" => 2)

    DeckardTestDatabase.with_destination do
      advance_destination_sequences

      loader = Deckard::Loader.new(stream)
      loader.load

      expect(loader.counts).to eq(dumper.counts)
      loader.counts.each do |type, count|
        expect(Object.const_get(type).count).to eq(count)
      end

      cloned_post = Post.find_by!(title: "Nexus-6 field notes")
      expect(post_snapshot(cloned_post)).to eq(source_snapshot)

      {"Author" => Author.ids, "Post" => Post.ids, "Comment" => Comment.ids}.each do |type, ids|
        expect(ids & source_ids.fetch(type)).to be_empty
      end

      # Loading the same stream again reuses every naturally keyed row and
      # inserts everything else afresh.
      stream.rewind
      keyed_rows = [Author.count, Category.count]
      expect { Deckard::Loader.new(stream).load }
        .to change(Post, :count).by(1).and change(Comment, :count).by(4)
      expect([Author.count, Category.count]).to eq(keyed_rows)
    end
  end

  it "clones an author's forum activity into another database" do
    source_author = Author.find_by!(username: "rachael")
    source_snapshot = author_snapshot(source_author)
    stream, dumper = stream(source_author)

    # Her own posts with their comments, the post she reacted to as a row,
    # and the authors those rows point at as rows: nothing they own.
    expect(dumper.counts).to eq(
      "Author" => 3, "Profile" => 1, "AuthorEmail" => 2, "Post" => 3, "Comment" => 4, "Category" => 1,
      "Reaction" => 2, "Donation" => 1, "Attachment" => 1, "AttachmentVariant" => 2
    )
    expect(Post.find_by!(title: "Unicorn origami").author.username).to eq("deckard")

    DeckardTestDatabase.with_destination do
      loader = Deckard::Loader.new(stream)
      loader.load

      expect(loader.counts).to eq(dumper.counts)
      expect(author_snapshot(Author.find_by!(username: "rachael"))).to eq(source_snapshot)
    end
  end
end
