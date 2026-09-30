# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Deckard
  # A replication plan: a root model's `replicate do ... end` block. The plan
  # is an entry for the root plus, through `model`, an entry for each class
  # its dumps reach, all in one table shared by the plan's entries. A class
  # finds its entry through its ancestors, so an STI subclass follows its
  # nearest declared ancestor. See docs/traversal.md.
  class ModelConfig
    attr_reader :name, :extra_associations, :natural_key_attributes, :omitted_fields, :omitted_associations

    @plans = {}

    class << self
      def declare(name, &block)
        @plans[name] = new(name).tap { |plan| plan.instance_eval(&block) }
      end

      def plan_for(klass)
        @plans.values_at(*klass.ancestors.map(&:name)).compact.first || NONE
      end

      # Every problem in every plan, so one run fixes them all.
      def validate!
        problems = @plans.each_value.flat_map(&:problems)
        raise ConfigurationError, problems.join("\n") unless problems.empty?
      end
    end

    def initialize(name = nil, entries = {})
      @name = name
      @entries = entries
      @entries[name] = self if name
      @resolved = {}
      @extra_associations = []
      @natural_key_attributes = []
      @omitted_fields = []
      @omitted_associations = []
    end

    # DSL: association names to dump beyond the automatic belongs_to and
    # has_one traversal. Additive across calls.
    def associations(*names)
      @extra_associations |= names.map(&:to_sym)
    end

    # DSL: attributes identifying an existing destination record to reuse.
    # Calling it again replaces the key.
    def natural_key(*attributes)
      @natural_key_attributes = attributes.map(&:to_s)
    end

    # DSL: fields to exclude from dumped attributes. Additive across calls.
    def omit_fields(*names)
      @omitted_fields |= names.map(&:to_s)
    end

    # DSL: associations not to traverse. Additive across calls.
    def omit_associations(*names)
      @omitted_associations |= names.map(&:to_sym)
    end

    # DSL: the entry for a class this plan's dumps reach.
    def model(name, &block)
      (@entries[name.to_s] ||= self.class.new(name.to_s, @entries)).instance_eval(&block)
    end

    # The entry that applies to klass, checked against it the first time.
    def for(klass)
      @resolved[klass] ||= (@entries.values_at(*klass.ancestors.map(&:name)).compact.first || NONE).tap do |entry|
        problems = entry.problems_for(klass)
        raise ConfigurationError, problems.join("\n") unless problems.empty?
      end
    end

    def problems
      @entries.each_value.flat_map do |entry|
        klass = entry.name.safe_constantize
        next ["#{entry.name.inspect} is named in a replicate block, but is not a loaded ActiveRecord model"] unless klass.respond_to?(:replicate)

        entry.problems_for(klass)
      end
    end

    # Everything this entry names that the model lacks or deckard cannot
    # traverse.
    def problems_for(model)
      problems = @extra_associations.filter_map do |name|
        reflection = model.reflect_on_association(name)
        if reflection.nil?
          "#{model} has no #{name.inspect} association"
        elsif reflection.macro == :has_and_belongs_to_many
          "#{model}.#{name} is a has_and_belongs_to_many association, " \
            "which deckard does not support; use an explicit join model and replicate that association instead"
        elsif reflection.macro == :has_many && reflection.through_reflection
          "#{model}.#{name} is a has_many :through association, " \
            "which deckard does not support; replicate :#{reflection.through_reflection.name} instead"
        end
      end
      attributes = @natural_key_attributes + @omitted_fields
      unless attributes.empty? || model.abstract_class?
        missing = attributes - model.attribute_names
        problems += missing.map { |attribute| "#{model} has no #{attribute.inspect} attribute" }
      end
      problems + (@natural_key_attributes & @omitted_fields).map do |attribute|
        "#{model} names #{attribute.inspect} as both a natural key attribute and an omitted field"
      end
    end

    # The plan as data, root entry first: what PlanReport renders.
    def to_h
      entries = @entries.each_value.map do |entry|
        {
          "model" => entry.name,
          "associations" => entry.extra_associations.map(&:to_s),
          "natural_key" => entry.natural_key_attributes,
          "omit_fields" => entry.omitted_fields,
          "omit_associations" => entry.omitted_associations.map(&:to_s)
        }
      end
      {"root" => @name, "entries" => entries}
    end

    # The entry for a class nothing declared: defaults only.
    NONE = new.freeze
  end
end
