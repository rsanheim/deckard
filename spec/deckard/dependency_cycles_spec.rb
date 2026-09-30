# frozen_string_literal: true

require_relative "../support/database_cleaner"
require_relative "../support/forum_models"

# Graphs where a record is reached again while its own dump is still in
# progress: belongs_to chains leading back to the record. Every such cycle
# must fail with a clear error and never produce a loadable stream.
RSpec.describe "dependency cycles", :db do
  def create_author(username, name = username.capitalize)
    Author.create!(username: username, name: name)
  end

  it "raises DumpError for two records that require each other, and the partial stream never loads" do
    rachael = create_author("rachael")
    post = Post.create!(author: rachael, title: "Nexus-6 field notes")
    rachael.update_columns(featured_post_id: post.id)

    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    expect { dumper.dump(rachael.reload) }.to raise_error(
      Deckard::DumpError,
      "dependency cycle detected: Post(#{post.id}).author references Author(#{rachael.id}), which cannot be emitted first"
    )

    io.rewind
    expect { Deckard::Loader.new(io).load }.to raise_error(Deckard::InvalidStream)
    expect(Author.count).to eq(1)
    expect(Post.count).to eq(1)
  end

  it "raises DumpError for a cycle that spans several records" do
    rachael = create_author("rachael")
    deckard = create_author("deckard")
    nexus = Post.create!(author: rachael, title: "Nexus-6 field notes")
    origami = Post.create!(author: deckard, title: "Unicorn origami")
    rachael.update_columns(featured_post_id: origami.id)
    deckard.update_columns(featured_post_id: nexus.id)

    expect { stream(rachael.reload) }.to raise_error(
      Deckard::DumpError,
      "dependency cycle detected: Post(#{nexus.id}).author references Author(#{rachael.id}), which cannot be emitted first"
    )
  end

  it "rolls back rows already loaded when the stream stops at a cycle", db: :multiple do
    gaff = create_author("gaff")
    rachael = create_author("rachael")
    post = Post.create!(author: rachael, title: "Nexus-6 field notes")
    rachael.update_columns(featured_post_id: post.id)

    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    dumper.dump(gaff)
    expect { dumper.dump(rachael.reload) }.to raise_error(Deckard::DumpError, /dependency cycle/)
    expect(dumper.counts).to eq("Author" => 1)

    DeckardTestDatabase.with_destination do
      io.rewind
      expect { Deckard::Loader.new(io).load }.to raise_error(Deckard::InvalidStream, /without an end marker/)
      expect(Author.count).to eq(0)
    end
  end

  it "raises DumpError for a record that references itself" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    comment = Comment.create!(post: post, author: author, body: "Talking to myself.")
    comment.update_columns(parent_id: comment.id)

    expect { stream(comment.reload) }
      .to raise_error(Deckard::DumpError, /dependency cycle detected: Comment\(#{comment.id}\)\.parent references Comment\(#{comment.id}\)/)
  end
end
