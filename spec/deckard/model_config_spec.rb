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

  it "fills one entry per class from a natural_keys table, one attribute or several" do
    plan = Deckard::ModelConfig.new("Order")
    plan.natural_keys "Customer" => :email, "Warehouse" => [:region, :code]
    plan.model("Customer") { omit_fields :password_digest }

    expect(plan.to_h["entries"].drop(1)).to eq([
      {"model" => "Customer", "associations" => [], "natural_key" => ["email"],
       "omit_fields" => ["password_digest"], "omit_associations" => []},
      {"model" => "Warehouse", "associations" => [], "natural_key" => %w[region code],
       "omit_fields" => [], "omit_associations" => []}
    ])
  end

  it "reports a natural key given twice for one class instead of letting the later one win" do
    plan = Deckard::ModelConfig.new("Order")
    plan.natural_keys "Customer" => :email
    plan.model("Customer") { natural_key :login }
    customer = Class.new do
      def self.name = "Customer"

      def self.to_s = name

      def self.abstract_class? = true
    end

    expect { plan.for(customer) }.to raise_error(
      Deckard::ConfigurationError, "Customer is given a natural key more than once in the same plan"
    )
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
