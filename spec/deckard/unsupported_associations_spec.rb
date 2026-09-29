# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/forum_models"

RSpec.describe "unsupported ActiveRecord associations", :db do
  it "rejects a selected HABTM association before emitting records" do
    author = Author.create!(username: "rachael", name: "Rachael")
    post = author.posts.create!(title: "Replicant writers club")
    author.bookmarked_posts << post
    dumper = Deckard::Dumper.new(StringIO.new)

    expect { dumper.dump(author, associations: [:bookmarked_posts]) }.to raise_error(
      Deckard::UnsupportedAssociation,
      "Author.bookmarked_posts is a has_and_belongs_to_many association, " \
        "which deckard does not support; use an explicit join model and replicate that association instead"
    )
    expect(dumper.counts).to be_empty
  end

  it "rejects a selected has_many through association with the join association to use" do
    author = Author.create!(username: "rachael", name: "Rachael")
    publisher = Author.create!(username: "stelline", name: "Ana Stelline")
    post = publisher.posts.create!(title: "Memory design")
    post.comments.create!(author: author, body: "Beautiful work")
    dumper = Deckard::Dumper.new(StringIO.new)

    expect { dumper.dump(author, associations: [:commented_posts]) }.to raise_error(
      Deckard::UnsupportedAssociation,
      "Author.commented_posts is a has_many :through association, " \
        "which deckard does not support; replicate :comments instead"
    )
    expect(dumper.counts).to be_empty
  end
end
