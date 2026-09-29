# frozen_string_literal: true

module Deckard
  # A replication plan. A model's `replicate do ... end` block is the plan
  # for dumps rooted at that model: what the root carries and, through
  # `model`, how each class those dumps reach is dumped and matched. A dump
  # follows its root's plan only; a reached class's own block is not
  # consulted. Classes are matched through their ancestors, so an STI
  # subclass follows the entry for its nearest declared ancestor.
  class ModelConfig
    attr_reader :name, :extra_associations, :natural_key_attributes, :omitted_fields, :omitted_associations

    @plans = {}

    class << self
      def declare(name, &block)
        @plans[name] = new(name).tap { |plan| plan.instance_eval(&block) }
      end

      # The plan for a dump rooted at klass.
      def plan_for(klass)
        klass.ancestors.each do |ancestor|
          plan = @plans[ancestor.name]
          return plan if plan
        end
        NONE
      end

      # Checks every plan before a stream starts: each named class is a
      # loaded ActiveRecord model naming only associations and attributes
      # it has. Reports every problem at once so one run fixes the plans.
      def validate!
        problems = @plans.values.flat_map(&:problems)
        raise ConfigurationError, problems.join("\n") unless problems.empty?
      end
    end

    def initialize(name = nil)
      @name = name
      @extra_associations = []
      @natural_key_attributes = []
      @omitted_fields = []
      @omitted_associations = []
      @models = {}
    end

    # DSL: additional association names to dump beyond the automatic
    # belongs_to and has_one traversal. Additive across calls.
    def associations(*names)
      @extra_associations |= names.map(&:to_sym)
    end

    # DSL: attributes identifying an existing destination record to reuse.
    # Calling it again replaces the key.
    def natural_key(*attributes)
      @natural_key_attributes = attributes.map(&:to_sym)
    end

    # DSL: fields to exclude from dumped attributes. Additive across calls.
    def omit_fields(*names)
      @omitted_fields |= names.map(&:to_sym)
    end

    # DSL: associations not to traverse. Additive across calls.
    def omit_associations(*names)
      @omitted_associations |= names.map(&:to_sym)
    end

    # DSL: how a class this plan's dumps reach is dumped and matched.
    def model(name, &block)
      (@models[name.to_s] ||= self.class.new(name.to_s)).instance_eval(&block)
    end

    # The part of this plan that applies to klass: the plan itself for its
    # root, the `model` entry for a class it reaches, defaults otherwise.
    def for(klass)
      klass.ancestors.each do |ancestor|
        return self if ancestor.name == @name

        entry = @models[ancestor.name]
        return entry if entry
      end
      NONE
    end

    def problems
      [self, *@models.values].filter_map do |config|
        klass = begin
          Object.const_get(config.name)
        rescue NameError
          nil
        end
        next "#{config.name.inspect} is named in a replicate block, but is not a loaded ActiveRecord model" unless klass.respond_to?(:replicate)

        config.validate!(klass)
        nil
      rescue ConfigurationError, UnsupportedAssociation => e
        e.message
      end
    end

    # Raises unless every association this plan names exists on the model
    # and is of a supported kind, and every attribute it names exists.
    def validate!(model)
      @extra_associations.each do |name|
        reflection = model.reflect_on_association(name)
        raise ConfigurationError, "#{model} has no #{name.inspect} association" unless reflection

        if reflection.macro == :has_and_belongs_to_many
          raise UnsupportedAssociation,
            "#{model}.#{name} is a has_and_belongs_to_many association, " \
            "which deckard does not support; use an explicit join model and replicate that association instead"
        end
        if reflection.macro == :has_many && reflection.through_reflection
          raise UnsupportedAssociation,
            "#{model}.#{name} is a has_many :through association, " \
            "which deckard does not support; replicate :#{reflection.through_reflection.name} instead"
        end
      end

      (@natural_key_attributes + @omitted_fields).each do |attribute|
        next if model.abstract_class? || model.attribute_names.include?(attribute.to_s)

        raise ConfigurationError, "#{model} has no #{attribute.inspect} attribute"
      end
    end

    # The plan for a class nothing declared: defaults only.
    NONE = new.freeze
  end
end
