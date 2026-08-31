# frozen_string_literal: true

RSpec.describe Deckard::ModelConfig do
  it "accumulates associations and both omission types additively across calls" do
    config = Deckard::ModelConfig.new
    config.associations :emails
    config.associations :memberships, :teams
    config.omit_fields :created_at
    config.omit_fields :encrypted_password
    config.omit_associations :profile

    expect(config.extra_associations).to eq(%i[emails memberships teams])
    expect(config.omitted_fields).to eq(%i[created_at encrypted_password])
    expect(config.omitted_associations).to eq([:profile])
  end

  it "replaces the natural key when defined again" do
    config = Deckard::ModelConfig.new
    config.natural_key :login
    config.natural_key :user_id, :email

    expect(config.natural_key_attributes).to eq(%i[user_id email])
  end

  it "configures target and block scalar references, replacing the same attribute" do
    config = Deckard::ModelConfig.new
    first = proc { |record, source_id| record.class.find_by(id: source_id) }
    replacement = proc { |record, source_id| record.class.find_by(id: source_id + 1) }

    config.scalar_reference :related_id, to: "Related"
    config.scalar_reference :resolved_id, &first
    config.scalar_reference :resolved_id, &replacement

    expect(config.scalar_references[:related_id].target).to eq("Related")
    expect(config.scalar_references[:related_id].resolver).to be_nil
    expect(config.scalar_references[:resolved_id].resolver).to be(replacement)
  end

  it "requires exactly one scalar reference resolver form" do
    config = Deckard::ModelConfig.new

    expect { config.scalar_reference :related_id }
      .to raise_error(ArgumentError, /exactly one/)
    expect { config.scalar_reference(:related_id, to: "Related") { Object.new } }
      .to raise_error(ArgumentError, /exactly one/)
  end

  it "copies parent configuration without sharing state" do
    parent = Deckard::ModelConfig.new
    parent.associations :emails
    parent.natural_key :login
    parent.scalar_reference :related_id, to: "Related"

    child = Deckard::ModelConfig.new(parent)
    child.associations :posts
    child.natural_key :slug
    child.omit_fields :secret
    child.omit_associations :profile
    child.scalar_reference :child_related_id, to: "ChildRelated"

    expect(child.extra_associations).to eq(%i[emails posts])
    expect(child.natural_key_attributes).to eq([:slug])
    expect(parent.extra_associations).to eq([:emails])
    expect(parent.natural_key_attributes).to eq([:login])
    expect(parent.omitted_fields).to eq([])
    expect(parent.omitted_associations).to eq([])
    expect(parent.scalar_references.keys).to eq([:related_id])
    expect(child.scalar_references.keys).to eq(%i[related_id child_related_id])
  end
end
