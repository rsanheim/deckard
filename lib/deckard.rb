# frozen_string_literal: true

require_relative "deckard/version"
require_relative "deckard/errors"
require_relative "deckard/dumper"
require_relative "deckard/loader"
require_relative "deckard/model_config"
require_relative "deckard/plan_report"
require_relative "deckard/active_record/dump"
require_relative "deckard/active_record/load"
require_relative "deckard/active_record"

require "active_support/lazy_load_hooks"
ActiveSupport.on_load(:active_record) do
  include Deckard::ActiveRecord
end

module Deckard
  # Whether the booted application looks like production. The loader
  # refuses to run there unless the operator passes --force.
  def self.production_environment?
    env = if defined?(::Rails) && ::Rails.respond_to?(:env)
      ::Rails.env.to_s
    else
      ENV["RAILS_ENV"] || ENV["RACK_ENV"]
    end
    env == "production"
  end

  # Stream protocol frames. The header opens every stream; the end marker
  # distinguishes a complete stream from one whose source died mid-dump.
  STREAM_HEADER = [:deckard, 2].freeze
  STREAM_END = [:deckard_end, 2].freeze
end
