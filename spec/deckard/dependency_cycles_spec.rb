# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/forum_models"

# Graphs where a record is reached again while its own dump is still in
# progress. A true cycle (belongs_to chains leading back to the record)
# must fail with a clear error and never produce a loadable stream. A
# record reached again through a collection, once its parents are written,
# must simply be emitted in order.
RSpec.describe "dependency cycles", :db do
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
    while (frame = Marshal.load(io)) != Deckard::STREAM_END
      result << frame unless frame == Deckard::STREAM_HEADER
    end
    result
  end

  it "raises DumpError for two records that require each other, and the partial stream never loads" do
    rachael = create_author("rachael")
    post = Post.create!(author: rachael, title: "Nexus-6 field notes")
    rachael.update_columns(featured_post_id: post.id)

    io = StringIO.new
    dumper = Deckard::Dumper.new(io)
    expect { dumper.dump(rachael.reload) }
      .to raise_error(Deckard::DumpError, /dependency cycle detected: (Author|Post)\(\d+\)\.(featured_post|author) references/)

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

    expect { stream(rachael.reload) }.to raise_error(Deckard::DumpError, /dependency cycle detected/)
  end

  it "raises DumpError for a record that references itself" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    comment = Comment.create!(post: post, author: author, body: "Talking to myself.")
    comment.update_columns(parent_id: comment.id)

    expect { stream(comment.reload) }
      .to raise_error(Deckard::DumpError, /dependency cycle detected: Comment\(#{comment.id}\)\.parent references Comment\(#{comment.id}\)/)
  end

  it "dumps a comment reached again through its post's configured comments before its reply" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    question = Comment.create!(post: post, author: author, body: "Have you ever retired a human by mistake?")
    reply = Comment.create!(post: post, author: author, parent: question, body: "I'm not in the business.")

    # question -> post -> post.comments (configured) -> reply -> parent: the
    # question is still in progress, but its own parents are written, so it
    # can be emitted right there.
    io, dumper = stream(question)

    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Comment" => 2)
    expect(frames(io).map { |type, id, _| [type, id] })
      .to eq([["Author", author.id], ["Post", post.id], ["Comment", question.id], ["Comment", reply.id]])

    io.rewind
    author.update_columns(username: "rachael-source")
    Deckard::Loader.new(io).load

    new_reply = Comment.where.not(id: [question.id, reply.id]).find_by!(body: "I'm not in the business.")
    expect(new_reply.parent.body).to eq("Have you ever retired a human by mistake?")
    expect(new_reply.parent.post_id).to eq(new_reply.post_id)
  end

  it "dumps a reply whose parent is reached through the post's configured comments" do
    author = create_author("rachael")
    post = Post.create!(author: author, title: "Nexus-6 field notes")
    question = Comment.create!(post: post, author: author, body: "Have you ever retired a human by mistake?")
    reply = Comment.create!(post: post, author: author, parent: question, body: "I'm not in the business.")

    io, dumper = stream(reply)

    expect(dumper.counts).to eq("Author" => 1, "Post" => 1, "Comment" => 2)
    expect(frames(io).map { |type, id, _| [type, id] })
      .to eq([["Author", author.id], ["Post", post.id], ["Comment", question.id], ["Comment", reply.id]])
  end
end
