# frozen_string_literal: true

require_relative "deckard/version"
require_relative "deckard/errors"
require_relative "deckard/dumper"
require_relative "deckard/loader"
require_relative "deckard/model_config"
require_relative "deckard/active_record"

require "active_support/lazy_load_hooks"
ActiveSupport.on_load(:active_record) do
  include Deckard::ActiveRecord
end

module Deckard
  # Stream protocol frames. The header opens every stream; the end marker
  # distinguishes a complete stream from one whose source died mid-dump.
  STREAM_HEADER = [:deckard, 1].freeze
  STREAM_END = [:deckard_end, 1].freeze
end
