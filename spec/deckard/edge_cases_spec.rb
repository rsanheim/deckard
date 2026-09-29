# frozen_string_literal: true

require "bigdecimal"
require "securerandom"
require_relative "../support/database_cleaner"
require_relative "../support/forum_models"

# Coverage of the ActiveRecord shapes spec section 13 supports (and the ones
# it requires to fail clearly), beyond the conventional models used elsewhere.
RSpec.describe "ActiveRecord edge cases", :db do
  def create_author(username, name = username.capitalize)
    Author.create!(username: username, name: name)
  end

  def uuid_pattern
    /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  end

  it "remaps database-generated UUID primary keys" do
    author = create_author("rachael")
    attachment = Attachment.create!(author: author, filename: "esper-photo.png")
    variant = AttachmentVariant.create!(attachment: attachment, variant: "thumbnail")

    io, _ = stream(variant)
    Deckard::Loader.new(io).load

    new_attachment = Attachment.where.not(id: attachment.id).sole
    new_variant = AttachmentVariant.where.not(id: variant.id).sole
    expect(new_attachment.id).to match(uuid_pattern)
    expect(new_attachment.id).not_to eq(attachment.id)
    expect(new_variant.attachment_id).to eq(new_attachment.id)
  end

  it "follows a self-referential belongs_to chain through threaded replies" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    question = Comment.create!(post: post, author: author, body: "Have you ever retired a human by mistake?")
    answer = Comment.create!(post: post, author: author, parent: question, body: "I'm not in the business.")
    followup = Comment.create!(post: post, author: author, parent: answer, body: "That's not an answer.")

    io, dumper = stream(followup)
    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Comment" => 3)

    Deckard::Loader.new(io).load

    new_followup = Comment.where.not(id: [question.id, answer.id, followup.id]).find_by!(body: "That's not an answer.")
    expect(new_followup.parent.body).to eq("I'm not in the business.")
    expect(new_followup.parent.parent.body).to eq("Have you ever retired a human by mistake?")
    expect(new_followup.parent.parent.parent).to be_nil
  end

  it "carries a record reached only by belongs_to as a row, whatever its entry owns" do
    rachael = create_author("rachael")
    deckard = create_author("deckard")
    Profile.create!(author: deckard, bio: "Ex-cop.")
    AuthorEmail.create!(author: deckard, address: "deckard@lapd.example")
    origami = Post.create!(author: deckard, title: "Unicorn origami")
    Comment.create!(post: origami, author: deckard, body: "Noted.")
    Reaction.create!(author: rachael, reactable: origami, kind: "like")

    # rachael's reaction needs deckard's post, and the post needs deckard.
    # Both arrive as rows: his profile (has_one), emails and posts (planned
    # collections) and the post's comments stay behind.
    _, dumper = stream(rachael)

    expect(dumper.counts).to eq("Author" => 2, "Post" => 1, "Reaction" => 1)
  end

  it "walks a record reached as a dependency first and owned later in one dump" do
    rachael = create_author("rachael")
    post = Post.create!(author: rachael, title: "Nexus-6 field notes")
    Reaction.create!(author: rachael, reactable: post, kind: "like")
    Comment.create!(post: post, author: rachael, body: "Noted.")

    # Author's plan names reactions before posts: the reaction reaches the
    # post as a dependency (a row), then the posts collection owns it and
    # its comments follow. The post is written once, where it first landed.
    io, dumper = stream(rachael)

    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Reaction" => 1, "Comment" => 1)
    expect(frames(io).map(&:first)).to eq(%w[Author Post Reaction Comment])
  end

  it "walks a record dumped as a dependency by one root when a later root owns it" do
    rachael = create_author("rachael")
    deckard = create_author("deckard")
    post = Post.create!(author: deckard, title: "Unicorn origami")
    Reaction.create!(author: rachael, reactable: post, kind: "like")
    Comment.create!(post: post, author: deckard, body: "Noted.")

    io, dumper = stream(Author.where(username: %w[rachael deckard]).order(:id))

    expect(dumper.counts).to eq("Author" => 2, "Reaction" => 1, "Post" => 1, "Comment" => 1)
    expect(frames(io).map { |type, id, _| [type, id] }.uniq.size).to eq(5)
    expect(frames(io).map(&:first)).to eq(%w[Author Author Post Reaction Comment])
  end

  it "references an STI subclass by its actual class and applies its nearest ancestor's entry" do
    author = create_author("gaff")
    category = AnnouncementCategory.create!(name: "Announcements", slug: "announcements", moderator_notes: "pin sparingly")
    post = Post.create!(author: author, category: category, title: "Welcome to the forum")

    io, _ = stream(post)

    frames = frames(io)
    expect(frames.map(&:first)).to eq(%w[Author AnnouncementCategory Post])
    category_frame = frames[1]
    expect(category_frame[3]).to eq(["slug"])
    expect(category_frame[2]["moderator_notes"]).to eq("pin sparingly")
    expect(frames.last[2]["category_id"]).to eq([:id, "AnnouncementCategory", category.id])
  end

  it "round trips jsonb, array, decimal, boolean, date, microsecond time, binary, uuid, and enum values" do
    author = Author.create!(
      username: "rachael",
      name: "Rachael",
      verified: true,
      role: "moderator",
      settings: {"theme" => "dark", "enhance" => [224, 176]},
      birthday: Date.new(2016, 1, 1),
      api_token: SecureRandom.uuid,
      avatar: "\x00\xFF\x01deckard".b,
      joined_at: Time.utc(2019, 11, 1, 12, 30, 45, 123_456)
    )
    post = Post.create!(author: author, title: "Esper photograph", keywords: %w[replicant nexus6])
    donation = Donation.create!(author: author, post: post, amount: BigDecimal("19.99"))

    io, _ = stream(donation)
    author.update_columns(username: "rachael-source")
    Deckard::Loader.new(io).load

    loaded = Author.where.not(id: author.id).sole
    expect(loaded.verified).to be(true)
    expect(loaded.role).to eq("moderator")
    expect(loaded.settings).to eq("theme" => "dark", "enhance" => [224, 176])
    expect(loaded.birthday).to eq(Date.new(2016, 1, 1))
    expect(loaded.api_token).to eq(author.api_token)
    expect(loaded.avatar).to eq("\x00\xFF\x01deckard".b)
    expect(loaded.joined_at).to eq(Time.utc(2019, 11, 1, 12, 30, 45, 123_456))
    expect(Post.where.not(id: post.id).sole.keywords).to eq(%w[replicant nexus6])
    expect(Donation.where.not(id: donation.id).sole.amount).to eq(BigDecimal("19.99"))
  end

  it "skips stored generated columns so the destination computes them" do
    author = create_author("rachael")
    source = Post.create!(author: author, title: "Esper photograph", body: "Enhance 224 to 176.")
    expect(source.search_vector).to include("'esper'")

    io, _ = stream(source)
    expect(frames(io).last[2]).not_to have_key("search_vector")

    Deckard::Loader.new(io).load

    expect(Post.where.not(id: source.id).sole.search_vector).to eq(source.search_vector)
  end

  it "round trips a native PostgreSQL enum column" do
    author = create_author("rachael")
    source = Post.create!(author: author, title: "Esper photograph", status: "published")

    io, _ = stream(source)
    Deckard::Loader.new(io).load

    expect(Post.where.not(id: source.id).sole.status).to eq("published")
  end

  it "carries encrypted attributes as plaintext in the stream and re-encrypts on load" do
    source = Author.create!(username: "rachael", name: "Rachael", private_notes: "unicorn dream")

    io, _ = stream(source)
    expect(frames(io).sole[2]["private_notes"]).to eq("unicorn dream")

    source.update_columns(username: "rachael-source")
    Deckard::Loader.new(io).load

    loaded = Author.where.not(id: source.id).sole
    expect(loaded.private_notes).to eq("unicorn dream")
    raw = Author.connection.select_value(
      "SELECT private_notes FROM authors WHERE id = #{Author.connection.quote(loaded.id)}"
    )
    expect(raw).not_to include("unicorn dream")
  end

  it "raises a clear error dumping a composite primary key model" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    view = PostView.create!(post: post, viewed_on: Date.new(2026, 9, 1), count: 42)

    expect { stream(view) }
      .to raise_error(Deckard::DumpError, /PostView has a composite primary key/)
  end

  it "raises a clear error loading into a composite primary key model" do
    io = StringIO.new
    Marshal.dump(Deckard::STREAM_HEADER, io)
    Marshal.dump(["PostView", 1, {"post_id" => 1, "viewed_on" => Date.new(2026, 9, 1), "count" => 42}, []], io)
    Marshal.dump(Deckard::STREAM_END, io)
    io.rewind

    expect { Deckard::Loader.new(io).load }
      .to raise_error(Deckard::LoadError, /PostView has a composite primary key/)
    expect(PostView.count).to eq(0)
  end
end
