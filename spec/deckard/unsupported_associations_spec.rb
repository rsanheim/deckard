# frozen_string_literal: true

require "stringio"
require_relative "../support/database_cleaner"
require_relative "../support/forum_models"

RSpec.describe "unsupported ActiveRecord associations", :db do
  it "rejects a plan naming a HABTM association before emitting records" do
    author = Bookmarker.create!(username: "rachael", name: "Rachael")
    dumper = Deckard::Dumper.new(StringIO.new)

    expect { dumper.dump(author) }.to raise_error(
      Deckard::ConfigurationError,
      "Bookmarker.bookmarked_posts is a has_and_belongs_to_many association, " \
        "which deckard does not support; use an explicit join model and replicate that association instead"
    )
    expect(dumper.counts).to be_empty
  end

  it "rejects a plan naming a has_many through association with the join association to use" do
    author = Commenter.create!(username: "rachael", name: "Rachael")
    dumper = Deckard::Dumper.new(StringIO.new)

    expect { dumper.dump(author) }.to raise_error(
      Deckard::ConfigurationError,
      "Commenter.commented_posts is a has_many :through association, " \
        "which deckard does not support; replicate :comments instead"
    )
    expect(dumper.counts).to be_empty
  end
end
