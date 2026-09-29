# frozen_string_literal: true

RSpec.describe Deckard::ModelConfig do
  it "accumulates associations and both omission types additively across calls" do
    plan = Deckard::ModelConfig.new("Widget")
    plan.associations :emails
    plan.associations :memberships, :teams
    plan.omit_fields :created_at
    plan.omit_fields :encrypted_password
    plan.omit_associations :profile

    expect(plan.extra_associations).to eq(%i[emails memberships teams])
    expect(plan.omitted_fields).to eq(%w[created_at encrypted_password])
    expect(plan.omitted_associations).to eq([:profile])
  end

  it "replaces the natural key when defined again" do
    plan = Deckard::ModelConfig.new("Widget")
    plan.natural_key :login
    plan.natural_key :user_id, :email

    expect(plan.natural_key_attributes).to eq(%w[user_id email])
  end

  it "describes itself as data, root entry first" do
    plan = Deckard::ModelConfig.new("Order")
    plan.associations :line_items
    plan.natural_key :number
    plan.model("Customer") do
      natural_key :email
      omit_fields :password_digest
      omit_associations :sessions
    end

    expect(plan.to_h).to eq(
      "root" => "Order",
      "entries" => [
        {"model" => "Order", "associations" => ["line_items"], "natural_key" => ["number"],
         "omit_fields" => [], "omit_associations" => []},
        {"model" => "Customer", "associations" => [], "natural_key" => ["email"],
         "omit_fields" => ["password_digest"], "omit_associations" => ["sessions"]}
      ]
    )
  end

  it "keeps every model entry in one table, however deeply it is declared" do
    plan = Deckard::ModelConfig.new("Order")
    plan.model("LineItem") { model("Adjustment") { natural_key :code } }
    order = Class.new { def self.name = "Order" }
    adjustment = Class.new do
      def self.name = "Adjustment"

      def self.abstract_class? = true
    end

    expect(plan.for(order)).to equal(plan)
    expect(plan.for(adjustment).natural_key_attributes).to eq(["code"])
  end
end
