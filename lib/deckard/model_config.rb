# frozen_string_literal: true

module Deckard
  # The replication plan. A root model's `replicate do ... end` block
  # declares the plan for itself and, through `model`, for every class its
  # dumps reach. Plans are keyed by class name; a class without one follows
  # its nearest ancestor with one, so STI subclasses need no declaration.
  class ModelConfig
    attr_reader :extra_associations, :natural_key_attributes, :omitted_fields, :omitted_associations

    @configs = {}

    class << self
      # Declarations for one name add up, whichever roots make them.
      def declare(name, &block)
        (@configs[name] ||= new).instance_eval(&block)
      end

      def for(klass)
        klass.ancestors.each do |ancestor|
          config = @configs[ancestor.name]
          return config if config
        end
        NONE
      end

      # Checks the whole plan before a stream starts: each declared name is a
      # loaded ActiveRecord model naming only associations and attributes it
      # has. Reports every problem at once so one run fixes the plan.
      def validate!
        problems = @configs.filter_map do |name, config|
          klass = begin
            Object.const_get(name)
          rescue NameError
            nil
          end
          next "#{name.inspect} is named in a replicate block, but is not a loaded ActiveRecord model" unless klass.respond_to?(:replicate)

          config.validate!(klass)
          nil
        rescue ConfigurationError, UnsupportedAssociation => e
          e.message
        end
        raise ConfigurationError, problems.join("\n") unless problems.empty?
      end

    end

    def initialize
      @extra_associations = []
      @natural_key_attributes = []
      @omitted_fields = []
      @omitted_associations = []
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

    # DSL: the plan for another class its dumps reach, by class name.
    def model(name, &block)
      self.class.declare(name.to_s, &block)
    end

    # This plan plus one dump call's options (associations, omit_fields,
    # omit_associations), for the records handed to that call.
    def with(options)
      plan = self.class.new
      plan.associations(*@extra_associations, *options[:associations])
      plan.natural_key(*@natural_key_attributes)
      plan.omit_fields(*@omitted_fields, *options[:omit_fields])
      plan.omit_associations(*@omitted_associations, *options[:omit_associations])
      plan
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
