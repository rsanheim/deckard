# frozen_string_literal: true

require "stringio"
require "deckard/status"

RSpec.describe Deckard::Status do
  it "writes the total and per-type counts sorted by type" do
    io = StringIO.new
    Deckard::Status.report("dumped", {"User" => 1, "CommitComment" => 95}, io)

    expect(io.string).to eq(<<~TEXT)
      dumped 96 total objects:

      CommitComment  95
      User            1
    TEXT
  end

  it "writes only the total line when nothing was counted" do
    io = StringIO.new
    Deckard::Status.report("loaded", {}, io)

    expect(io.string).to eq("loaded 0 total objects:\n")
  end
end
