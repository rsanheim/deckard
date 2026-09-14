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

  it "inherits replicate configuration in subclasses" do
    category = AnnouncementCategory.create!(name: "Announcements", slug: "announcements", moderator_notes: "pin sparingly")

    io, dumper = stream(category)
    expect(dumper.counts).to eq("AnnouncementCategory" => 1)
    expect(frames(io).sole[2]).not_to have_key("moderator_notes")

    io.rewind
    Deckard::Loader.new(io).load
    expect(Category.sole).to eq(category)
  end

  it "raises DumpError when a replicate block names a missing association" do
    broken = MisconfiguredCategory.create!(name: "broken", slug: "broken")

    expect { stream(broken) }.to raise_error(Deckard::DumpError, /moderators/)
  end

  it "includes per-dump associations, skipping classes that lack them" do
    author = create_author("rachael")
    Profile.create!(author: author, bio: "More human than human")
    Post.create!(author: author, title: "Nexus-6 field notes")

    # :posts cascades to Profile too, which has no such association - that
    # must be skipped, not raised.
    _, dumper = stream(author, associations: [:posts])

    expect(dumper.counts).to eq("Author" => 1, "Profile" => 1, "Post" => 1)
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
