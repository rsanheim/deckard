# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/forum_models"

RSpec.describe "replicate model DSL", :db do
  def create_author(username, name = username.capitalize)
    Author.create!(username: username, name: name)
  end

  def stream(objects)
    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    Array(objects).each { |object| dumper.dump(object) }
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

  it "dumps has_many associations the plan names" do
    author = create_author("rachael")
    attachment = Attachment.create!(author: author, filename: "esper-photo.png")
    %w[thumbnail enhanced].each { |variant| AttachmentVariant.create!(attachment: attachment, variant: variant) }

    io, dumper = stream(attachment)
    expect(dumper.counts).to eq("Author" => 1, "Attachment" => 1, "AttachmentVariant" => 2)

    Deckard::Loader.new(io).load
    new_attachment = Attachment.where.not(id: attachment.id).sole
    expect(new_attachment.variants.count).to eq(2)
  end

  it "omits attributes the plan names" do
    category = Category.create!(name: "General", slug: "general", moderator_notes: "watch for spam")

    io, _ = stream(category)

    category_frame = frames(io).find { |type, _, _| type == "Category" }
    expect(category_frame[2]).not_to have_key("moderator_notes")

    io.rewind
    category.update_columns(slug: "general-source")
    Deckard::Loader.new(io).load
    expect(Category.where.not(id: category.id).sole.moderator_notes).to be_nil
  end

  it "follows the nearest ancestor's plan for a subclass root" do
    category = AnnouncementCategory.create!(name: "Announcements", slug: "announcements", moderator_notes: "pin sparingly")

    io, dumper = stream(category)
    expect(dumper.counts).to eq("AnnouncementCategory" => 1)
    expect(frames(io).sole[2]).not_to have_key("moderator_notes")

    io.rewind
    Deckard::Loader.new(io).load
    expect(Category.sole).to eq(category)
  end

  it "raises ConfigurationError when a plan names a missing association" do
    broken = MisconfiguredCategory.create!(name: "broken", slug: "broken")

    expect { stream(broken) }.to raise_error(Deckard::ConfigurationError, "MisconfiguredCategory has no :moderators association")
  end

  it "applies the root's entry for a class defined after it" do
    expect(Deckard::ModelConfig.plan_for(Post).for(Comment).extra_associations).to eq([:replies])

    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    question = Comment.create!(post: post, author: author, body: "Have you ever retired a human by mistake?")
    Comment.create!(post: post, author: author, parent: question, body: "I'm not in the business.")

    _, dumper = stream(post)
    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Comment" => 2)
  end

  it "dumps a reached class by the root's plan, not by that class's own block" do
    author = create_author("rachael")
    category = Category.create!(name: "General", slug: "general", moderator_notes: "watch for spam")
    post = Post.create!(author: author, category: category, title: "Nexus-6 field notes")

    io, _ = stream(post)

    # Category's own plan omits moderator_notes; Post's entry for it does not.
    category_frame = frames(io).find { |type, _, _| type == "Category" }
    expect(category_frame[2]["moderator_notes"]).to eq("watch for spam")
    expect(category_frame[3]).to eq(["slug"])
  end

  it "validates every plan, reporting every problem at once" do
    expect { Deckard::ModelConfig.validate! }.to raise_error(Deckard::ConfigurationError) do |error|
      expect(error.message.lines.map(&:chomp)).to contain_exactly(
        '"Moderator" is named in a replicate block, but is not a loaded ActiveRecord model',
        "MisconfiguredCategory has no :moderators association",
        "Bookmarker.bookmarked_posts is a has_and_belongs_to_many association, " \
          "which deckard does not support; use an explicit join model and replicate that association instead",
        "Commenter.commented_posts is a has_many :through association, " \
          "which deckard does not support; replicate :comments instead"
      )
    end
  end

  it "omitting a belongs_to association skips traversal but preserves its foreign key" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    tag = Tag.create!(name: "replicants", slug: "replicants")
    post_tag = PostTag.create!(post: post, tag: tag)

    io, dumper = stream(post_tag)
    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "PostTag" => 1)

    Deckard::Loader.new(io).load

    expect(PostTag.where.not(id: post_tag.id).sole.tag_id).to eq(tag.id)
  end

  it "omitting a foreign-key field still traverses the association" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    donation = Donation.create!(author: author, post: post, amount: 5)

    io, dumper = stream(donation)
    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Donation" => 1)
    expect(frames(io).last[2]).not_to have_key("post_id")

    io.rewind
    Deckard::Loader.new(io).load

    expect(Donation.where.not(id: donation.id).sole.post_id).to be_nil
  end

  it "reuses and updates an existing destination record matched by natural key" do
    source_author = Author.create!(username: "rob", name: "Rob", email: "rob@source.example")
    AuthorEmail.create!(author: source_author, address: "rob@shared.example", label: "from-source")
    io, _ = stream(AuthorEmail.all)

    DeckardTestDatabase.truncate
    existing = Author.create!(username: "rob", name: "Rob", email: "rob@dest.example")
    AuthorEmail.create!(author: existing, address: "rob@shared.example", label: "stale")

    Author.callbacks_fired.clear
    Deckard::Loader.new(io).load

    expect(Author.callbacks_fired).to be_empty
    expect(Author.sole.id).to eq(existing.id)
    expect(Author.sole.email).to eq("rob@source.example")
    email = AuthorEmail.sole
    expect(email.author_id).to eq(existing.id)
    expect(email.label).to eq("from-source")
  end

  it "creates a new record when the natural key matches nothing" do
    Author.create!(username: "rob", name: "Rob", email: "rob@source.example")
    io, _ = stream(Author.all)

    DeckardTestDatabase.truncate
    Deckard::Loader.new(io).load

    expect(Author.sole.username).to eq("rob")
  end

  it "fails and rolls back when the natural key is ambiguous" do
    Tag.create!(name: "replicants", slug: "replicants")
    io, _ = stream(Tag.all)

    DeckardTestDatabase.truncate
    Tag.create!(name: "replicants", slug: "replicants-first")
    Tag.create!(name: "replicants", slug: "replicants-second")

    expect { Deckard::Loader.new(io).load }
      .to raise_error(Deckard::LoadError, /natural key \(name\) matches more than one/)
    expect(Tag.pluck(:slug)).to match_array(["replicants-first", "replicants-second"])
  end
end
