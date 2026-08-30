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

  it "copies parent configuration without sharing state" do
    parent = Deckard::ModelConfig.new
    parent.associations :emails
    parent.natural_key :login

    child = Deckard::ModelConfig.new(parent)
    child.associations :posts
    child.natural_key :slug
    child.omit_fields :secret
    child.omit_associations :profile

    expect(child.extra_associations).to eq(%i[emails posts])
    expect(child.natural_key_attributes).to eq([:slug])
    expect(parent.extra_associations).to eq([:emails])
    expect(parent.natural_key_attributes).to eq([:login])
    expect(parent.omitted_fields).to eq([])
    expect(parent.omitted_associations).to eq([])
  end
end
