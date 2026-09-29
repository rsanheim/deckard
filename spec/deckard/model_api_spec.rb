# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/forum_models"

RSpec.describe "replicate model DSL", :db do
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
    author = create_author("rachael")
    attachment = Attachment.create!(author: author, filename: "esper-photo.png")
    %w[thumbnail enhanced].each { |variant| AttachmentVariant.create!(attachment: attachment, variant: variant) }

    io, dumper = stream(attachment)
    expect(dumper.counts).to eq("Author" => 1, "Attachment" => 1, "AttachmentVariant" => 2)

    Deckard::Loader.new(io).load
    new_attachment = Attachment.where.not(id: attachment.id).sole
    expect(new_attachment.variants.count).to eq(2)
  end

  it "omits attributes configured in the replicate block" do
    category = Category.create!(name: "General", slug: "general", moderator_notes: "watch for spam")

    io, _ = stream(category)

    category_frame = frames(io).find { |type, _, _| type == "Category" }
    expect(category_frame[2]).not_to have_key("moderator_notes")

    io.rewind
    category.update_columns(slug: "general-source")
    Deckard::Loader.new(io).load
    expect(Category.where.not(id: category.id).sole.moderator_notes).to be_nil
  end

  it "applies the nearest ancestor's plan to a subclass" do
    category = AnnouncementCategory.create!(name: "Announcements", slug: "announcements", moderator_notes: "pin sparingly")

    io, dumper = stream(category)
    expect(dumper.counts).to eq("AnnouncementCategory" => 1)
    expect(frames(io).sole[2]).not_to have_key("moderator_notes")

    io.rewind
    Deckard::Loader.new(io).load
    expect(Category.sole).to eq(category)
  end

  it "raises ConfigurationError when a replicate block names a missing association" do
    broken = MisconfiguredCategory.create!(name: "broken", slug: "broken")

    expect { stream(broken) }.to raise_error(Deckard::ConfigurationError, /MisconfiguredCategory names :moderators/)
  end

  it "applies a root model's plan for a class defined after it" do
    expect(Deckard::ModelConfig.for(Comment).extra_associations).to eq([:replies])

    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    question = Comment.create!(post: post, author: author, body: "Have you ever retired a human by mistake?")
    Comment.create!(post: post, author: author, parent: question, body: "I'm not in the business.")

    _, dumper = stream(post)
    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Comment" => 2)
  end

  it "applies a root model's plan for a class defined before it" do
    config = Deckard::ModelConfig.for(Category)

    expect(config.natural_key_attributes).to eq([:slug])
    expect(config.omitted_fields).to eq([:moderator_notes])
  end

  it "validates the whole plan, reporting every problem at once" do
    expect { Deckard::ModelConfig.validate! }.to raise_error(Deckard::ConfigurationError) do |error|
      expect(error.message.lines.map(&:chomp)).to contain_exactly(
        '"Moderator" is named in a replicate block, but is not a loaded ActiveRecord model',
        "MisconfiguredCategory names :moderators in its replicate configuration, but no such association exists"
      )
    end
  end

  it "applies per-dump associations to the dumped object only" do
    rachael = create_author("rachael")
    deckard = create_author("deckard")
    post = Post.create!(author: rachael, title: "Nexus-6 field notes")
    Donation.create!(author: deckard, post: post, amount: 5)

    # Post has donations too, but the option applies to rachael alone.
    _, dumper = stream(rachael, associations: [:posts, :donations])

    expect(dumper.counts).to eq("Author" => 1, "Post" => 1)
  end

  it "raises DumpError when a per-dump association is missing on the dumped object" do
    author = create_author("rachael")

    expect { stream(author, associations: [:variants]) }
      .to raise_error(Deckard::DumpError, /Author has no :variants association/)
  end

  it "applies per-dump field and association omissions independently" do
    author = create_author("rachael")
    Profile.create!(author: author, bio: "unused")

    io, dumper = stream(author, omit_fields: [:created_at], omit_associations: [:profile])

    expect(dumper.counts).to eq("Author" => 1)
    expect(frames(io).first[2]).not_to have_key("created_at")
  end

  it "omitting a belongs_to association skips traversal but preserves its foreign key" do
    author = create_author("rachael")
    category = Category.create!(name: "General", slug: "general")
    post = Post.create!(author: author, category: category, title: "Nexus-6 field notes")

    io, dumper = stream(post, omit_associations: [:category])
    expect(dumper.counts).to eq("Author" => 1, "Post" => 1)

    Deckard::Loader.new(io).load

    expect(Post.where.not(id: post.id).sole.category_id).to eq(category.id)
  end

  it "omitting a foreign-key field still traverses the association" do
    author = create_author("rachael")
    category = Category.create!(name: "General", slug: "general")
    post = Post.create!(author: author, category: category, title: "Nexus-6 field notes")

    io, dumper = stream(post, omit_fields: [:category_id])
    expect(dumper.counts).to eq("Author" => 1, "Category" => 1, "Post" => 1)
    expect(frames(io).last[2]).not_to have_key("category_id")

    io.rewind
    Deckard::Loader.new(io).load

    expect(Post.where.not(id: post.id).sole.category_id).to be_nil
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
