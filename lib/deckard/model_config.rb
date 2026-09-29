# frozen_string_literal: true

module Deckard
  # Backs the `replicate do ... end` model DSL. One instance per model class,
  # keyed by class name. A subclass copies its superclass's configuration
  # when its own config is first touched, so mutating one class never
  # mutates another. A block declared for another model via `model` is held
  # until that class first asks for its configuration, so a root model can
  # name classes that load after it.
  class ModelConfig
    attr_reader :extra_associations, :natural_key_attributes, :omitted_fields, :omitted_associations

    @configs = {}
    @declared = Hash.new { |declared, name| declared[name] = [] }

    class << self
      # The chain of parent configurations stops at the first ancestor
      # without the `replicate` DSL, which is ActiveRecord::Base's own
      # superclass.
      def for(klass)
        @configs[klass.name] ||= begin
          config = new(klass.superclass.respond_to?(:replicate) ? self.for(klass.superclass) : nil)
          @declared.delete(klass.name)&.each { |block| config.instance_eval(&block) }
          config
        end
      end

      def declare(name, &block)
        if (config = @configs[name])
          config.instance_eval(&block)
        else
          @declared[name] << block
        end
      end

      # Checks every configuration in the process before a stream starts:
      # each declared model is a loaded ActiveRecord class, and each names
      # only associations and attributes it has. Reports every problem at
      # once so one run fixes the whole plan.
      def validate!
        problems = @declared.keys.filter_map do |name|
          klass = begin
            Object.const_get(name)
          rescue NameError
            nil
          end
          next "#{name.inspect} is named in a replicate block, but is not a loaded ActiveRecord model" unless klass.respond_to?(:replicate)

          self.for(klass)
          nil
        end
        @configs.each do |name, config|
          config.validate!(Object.const_get(name))
        rescue ConfigurationError, UnsupportedAssociation => e
          problems << e.message
        end
        raise ConfigurationError, problems.join("\n") unless problems.empty?
      end

      # `subject` names the model, with the record's source id when one is
      # being dumped.
      def supported_association!(reflection, subject)
        if reflection.macro == :has_and_belongs_to_many
          raise UnsupportedAssociation,
            "#{subject}.#{reflection.name} is a has_and_belongs_to_many association, " \
            "which deckard does not support; use an explicit join model and replicate that association instead"
        end

        return unless reflection.macro == :has_many && reflection.through_reflection

        raise UnsupportedAssociation,
          "#{subject}.#{reflection.name} is a has_many :through association, " \
          "which deckard does not support; replicate :#{reflection.through_reflection.name} instead"
      end
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

    # DSL: configuration for another model, given by class name, exactly as
    # if written in that model's own replicate block. Lets one root model
    # hold the configuration for every model its dumps reach.
    def model(name, &block)
      self.class.declare(name.to_s, &block)
    end

    # Raises unless every association and attribute this configuration
    # names exists on the model.
    def validate!(model)
      @extra_associations.each do |name|
        reflection = model.reflect_on_association(name)
        unless reflection
          raise ConfigurationError, "#{model} names #{name.inspect} in its replicate configuration, but no such association exists"
        end
        self.class.supported_association!(reflection, model)
      end

      (@natural_key_attributes + @omitted_fields).each do |attribute|
        next if model.abstract_class? || model.attribute_names.include?(attribute.to_s)

        raise ConfigurationError, "#{model} names #{attribute.inspect} in its replicate configuration, but no such attribute exists"
      end
    end
  end
end
