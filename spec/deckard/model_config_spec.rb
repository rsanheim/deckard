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
end
