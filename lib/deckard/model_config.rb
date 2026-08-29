# frozen_string_literal: true

module Deckard
  # Backs the `replicate do ... end` model DSL. One instance per model class.
  # A subclass copies its superclass's configuration when its own config is
  # first touched, so mutating one class never mutates another.
  class ModelConfig
    attr_reader :extra_associations, :natural_key_attributes, :omissions

    def initialize(parent = nil)
      @extra_associations = parent ? parent.extra_associations.dup : []
      @natural_key_attributes = parent ? parent.natural_key_attributes.dup : []
      @omissions = parent ? parent.omissions.dup : []
    end

    # DSL: additional association names to dump beyond the automatic
    # belongs_to and has_one traversal. Additive across calls.
    def associations(*names)
      @extra_associations.concat(names.map(&:to_sym))
    end

    # DSL: attributes identifying an existing destination record to reuse.
    # Calling it again (e.g. in a subclass) replaces the key.
    def natural_key(*attributes)
      @natural_key_attributes = attributes.map(&:to_sym)
    end

    # DSL: attribute and association names to exclude from the stream.
    # Additive across calls.
    def omit(*names)
      @omissions.concat(names.map(&:to_sym))
    end
  end
end
