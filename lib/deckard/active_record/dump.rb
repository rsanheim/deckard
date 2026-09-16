# frozen_string_literal: true

module Deckard
  module ActiveRecord
    # Dumps one record and its dependencies. Traversal order: belongs_to
    # associations, the record itself, has_one associations, then
    # associations configured via `replicate` or per-dump options. has_many
    # associations are never followed automatically. Per-dump options apply
    # to the record handed to Dumper#dump only; records reached from it are
    # dumped with their own model configuration.
    class Dump
      # Stored generated columns (GENERATED ALWAYS AS ... STORED) are never
      # dumped: the destination database computes them, and PostgreSQL
      # rejects explicit inserts into them. Computed once per model class.
      GENERATED_COLUMNS = Hash.new do |cache, model|
        cache[model] = model.columns.select { |column| column.respond_to?(:virtual?) && column.virtual? }.map(&:name)
      end

      def self.source_id(record)
        if record.class.primary_key.is_a?(Array)
          raise DumpError, "#{record.class} has a composite primary key, which deckard does not support"
        end
        record.id
      end

      def initialize(record, dumper, options)
        @record = record
        @model = record.class
        @source_id = self.class.source_id(record)
        @dumper = dumper
        @options = options
        config = ModelConfig.for(@model)
        @configured_associations = config.extra_associations
        @omitted_fields = config.omitted_fields + Array(options[:omit_fields]).map(&:to_sym)
        @omitted_associations = config.omitted_associations + Array(options[:omit_associations]).map(&:to_sym)
      end

      def call
        @dumper.once(@model.name, @source_id) do
          validate_selected_associations!
          attributes = @record.attributes.except(*GENERATED_COLUMNS[@model], *@omitted_fields.map(&:to_s))
          dump_belongs_to(attributes)
          @dumper.write(@model.name, @source_id, attributes, @record)
          dump_has_one
          dump_configured
        end
      end

      private

      def dump_belongs_to(attributes)
        @model.reflect_on_all_associations(:belongs_to).each do |reflection|
          foreign_key = reflection.foreign_key.to_s
          next if @omitted_associations.include?(reflection.name)
          next if encode_dumped_parent(attributes, reflection, foreign_key)

          referenced = @record.public_send(reflection.name)
          next if referenced.nil?

          @dumper.dump(referenced)
          referenced_id = self.class.source_id(referenced)
          unless @dumper.dumped?(referenced.class.name, referenced_id)
            raise DumpError,
              "dependency cycle detected: #{@model}(#{@source_id}).#{reflection.name} " \
              "references #{referenced.class.name}(#{referenced_id}), which cannot be emitted first"
          end
          next if @omitted_fields.include?(foreign_key.to_sym)
          # A belongs_to whose primary_key option targets a non-primary-key
          # column (belongs_to :account, primary_key: :login) carries a natural
          # value, not a source ID. It needs no remapping and must not be
          # replaced with a destination primary key.
          next unless reflection.association_primary_key(referenced.class) == referenced.class.primary_key

          attributes[foreign_key] = [:id, referenced.class.name, referenced_id]
        end
      end

      # When the parent is already in the stream under the association's
      # declared class, encode the reference from the foreign key alone
      # instead of loading the parent again. A parent dumped as an STI
      # subclass misses this check and takes the loading path.
      def encode_dumped_parent(attributes, reflection, foreign_key)
        return false if reflection.polymorphic?
        return false unless reflection.association_primary_key == reflection.klass.primary_key

        value = @record[foreign_key]
        return false if value.nil? || !@dumper.dumped?(reflection.klass.name, value)

        attributes[foreign_key] = [:id, reflection.klass.name, value] unless @omitted_fields.include?(foreign_key.to_sym)
        true
      end

      def dump_has_one
        @model.reflect_on_all_associations(:has_one).each do |reflection|
          next if @omitted_associations.include?(reflection.name)
          dependent = @record.public_send(reflection.name)
          @dumper.dump(dependent) if dependent
        end
      end

      # Every selected association must exist on this model: those named in
      # the model's `replicate` block, and those passed for this dump call.
      def validate_selected_associations!
        @configured_associations.each do |name|
          next if @omitted_associations.include?(name)

          reflection = @model.reflect_on_association(name)
          unless reflection
            raise DumpError, "#{@model} names #{name.inspect} in its replicate block, but no such association exists"
          end
          validate_association!(reflection)
        end

        per_dump_associations.each do |name|
          reflection = @model.reflect_on_association(name)
          unless reflection
            raise DumpError, "#{@model} has no #{name.inspect} association to dump"
          end
          validate_association!(reflection)
        end
      end

      def validate_association!(reflection)
        if reflection.macro == :has_and_belongs_to_many
          raise UnsupportedAssociation,
            "#{@model}(#{@source_id}).#{reflection.name} is a has_and_belongs_to_many association, " \
            "which deckard does not support; use an explicit join model and replicate that association instead"
        end

        return unless reflection.macro == :has_many && reflection.through_reflection

        raise UnsupportedAssociation,
          "#{@model}(#{@source_id}).#{reflection.name} is a has_many :through association, " \
          "which deckard does not support; replicate :#{reflection.through_reflection.name} instead"
      end

      def per_dump_associations
        Array(@options[:associations]).map(&:to_sym).reject do |name|
          @omitted_associations.include?(name) || @configured_associations.include?(name)
        end
      end

      def dump_configured
        @configured_associations.each do |name|
          next if @omitted_associations.include?(name)
          dump_association(name)
        end

        per_dump_associations.each { |name| dump_association(name) }
      end

      def dump_association(name)
        associated = @record.public_send(name)
        @dumper.dump(associated) if associated
      end
    end
  end
end
