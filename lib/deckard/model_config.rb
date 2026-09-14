# frozen_string_literal: true

module Deckard
  # Backs the `replicate do ... end` model DSL. One instance per model class.
  # A subclass copies its superclass's configuration when its own config is
  # first touched, so mutating one class never mutates another.
  class ModelConfig
    attr_reader :extra_associations, :natural_key_attributes, :omitted_fields, :omitted_associations

    # One configuration per model class, created on first use. A subclass
    # starts from its superclass's configuration; the chain stops at the
    # first ancestor without the `replicate` DSL, which is ActiveRecord::Base's
    # own superclass.
    def self.for(klass)
      @configs ||= {}
      @configs[klass] ||= new(klass.superclass.respond_to?(:replicate) ? self.for(klass.superclass) : nil)
    end

    def initialize(parent = nil)
      @extra_associations = parent ? parent.extra_associations.dup : []
      @natural_key_attributes = parent ? parent.natural_key_attributes.dup : []
      @omitted_fields = parent ? parent.omitted_fields.dup : []
      @omitted_associations = parent ? parent.omitted_associations.dup : []
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

    # DSL: fields to exclude from dumped attributes. Additive across calls.
    def omit_fields(*names)
      @omitted_fields.concat(names.map(&:to_sym))
    end

    # DSL: associations not to traverse. Additive across calls.
    def omit_associations(*names)
      @omitted_associations.concat(names.map(&:to_sym))
    end
  end
end
