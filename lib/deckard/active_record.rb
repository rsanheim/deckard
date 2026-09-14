# frozen_string_literal: true

module Deckard
  # Implements the replicant protocol for ActiveRecord models. Included into
  # ActiveRecord::Base when ActiveRecord loads (see lib/deckard.rb). Models
  # gain exactly three methods: the `replicate` configuration DSL,
  # `dump_replicant`, and `load_replicant`. Traversal and loading live in
  # the plain objects below so nothing else lands in the model namespace.
  module ActiveRecord
    def self.included(base)
      base.extend ClassMethods
    end

    def dump_replicant(dumper, options = {})
      Dump.new(self, dumper, options).call
    end

    module ClassMethods
      # The `replicate do ... end` model DSL.
      def replicate(&block)
        ModelConfig.for(self).instance_eval(&block)
      end

      # Load one streamed replicant: reuse an existing row when a natural key
      # matches, otherwise insert a new row with a destination-generated
      # primary key. Both paths bypass validations and callbacks.
      def load_replicant(type, source_id, attributes)
        Load.new(self, type, source_id, attributes).call
      end
    end

    # Dumps one record and its dependencies. Traversal order: belongs_to
    # associations, the record itself, has_one associations, then
    # associations configured via `replicate` or per-dump options. has_many
    # associations are never followed automatically.
    class Dump
      def self.source_id(record)
        if record.class.primary_key.is_a?(Array)
          raise DumpError, "#{record.class} has a composite primary key, which deckard does not support"
        end
        record.id
      end

      def initialize(record, dumper, options)
        @record = record
        @model = record.class
        @dumper = dumper
        @options = options
        config = ModelConfig.for(@model)
        @configured_associations = config.extra_associations
        @omitted_fields = config.omitted_fields + Array(options[:omit_fields]).map(&:to_sym)
        @omitted_associations = config.omitted_associations + Array(options[:omit_associations]).map(&:to_sym)
      end

      def call
        @dumper.once(@model.name, source_id) do
          validate_selected_associations!
          attributes = @record.attributes.except(*generated_columns, *@omitted_fields.map(&:to_s))
          dump_belongs_to(attributes)
          @dumper.write(@model.name, source_id, attributes, @record)
          dump_has_one
          dump_configured
        end
      end

      private

      def source_id
        self.class.source_id(@record)
      end

      # Stored generated columns (GENERATED ALWAYS AS ... STORED) are never
      # dumped: the destination database computes them, and PostgreSQL
      # rejects explicit inserts into them.
      def generated_columns
        @model.columns.select { |column| column.respond_to?(:virtual?) && column.virtual? }.map(&:name)
      end

      def dump_belongs_to(attributes)
        @model.reflect_on_all_associations(:belongs_to).each do |reflection|
          foreign_key = reflection.foreign_key.to_s
          next if @omitted_associations.include?(reflection.name)

          referenced = @record.public_send(reflection.name)
          next if referenced.nil?

          @dumper.dump(referenced, @options)
          referenced_id = self.class.source_id(referenced)
          unless @dumper.dumped?(referenced.class.name, referenced_id)
            raise DumpError,
              "dependency cycle detected: #{@model}(#{source_id}).#{reflection.name} " \
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

      def dump_has_one
        @model.reflect_on_all_associations(:has_one).each do |reflection|
          next if @omitted_associations.include?(reflection.name)
          dependent = @record.public_send(reflection.name)
          @dumper.dump(dependent, @options) if dependent
        end
      end

      # Associations named in the model's `replicate` block must exist; names
      # passed per-dump are skipped on classes that lack them, because options
      # cascade to every record reached in the traversal.
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
          validate_association!(reflection) if reflection
        end
      end

      def validate_association!(reflection)
        if reflection.macro == :has_and_belongs_to_many
          raise UnsupportedAssociation,
            "#{@model}(#{source_id}).#{reflection.name} is a has_and_belongs_to_many association, " \
            "which deckard does not support; use an explicit join model and replicate that association instead"
        end

        return unless reflection.macro == :has_many && reflection.through_reflection

        raise UnsupportedAssociation,
          "#{@model}(#{source_id}).#{reflection.name} is a has_many :through association, " \
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

        per_dump_associations.each do |name|
          next unless @model.reflect_on_association(name)
          dump_association(name)
        end
      end

      def dump_association(name)
        associated = @record.public_send(name)
        @dumper.dump(associated, @options) if associated
      end
    end

    # Loads one replicant tuple into a model's table.
    class Load
      def initialize(model, type, source_id, attributes)
        @model = model
        @type = type
        @source_id = source_id
        @attributes = attributes
      end

      def call
        if @model.primary_key.is_a?(Array)
          raise LoadError, "#{@model.name} has a composite primary key, which deckard does not support"
        end

        key = ModelConfig.for(@model).natural_key_attributes
        key.empty? ? insert : load_by_natural_key(key)
      end

      private

      def insert
        result = @model.insert_all!([@attributes.except(@model.primary_key)], returning: [@model.primary_key])
        destination_id = result.rows.first.first
        [destination_id, @model.find(destination_id)]
      rescue ::ActiveRecord::ActiveRecordError => e
        raise InsertError,
          "#{@type} source_id=#{@source_id} could not be inserted: #{Deckard.error_detail(e)}"
      end

      def load_by_natural_key(key)
        lookup = key.to_h { |attribute| [attribute.to_s, @attributes[attribute.to_s]] }
        matches = @model.where(lookup).limit(2).to_a

        case matches.size
        when 0
          insert
        when 1
          record = matches.first
          begin
            record.update_columns(@attributes.except(@model.primary_key))
          rescue ::ActiveRecord::ActiveRecordError => e
            raise InsertError,
              "#{@type} source_id=#{@source_id} could not be updated via natural key: #{Deckard.error_detail(e)}"
          end
          [record.id, record]
        else
          raise LoadError,
            "#{@type} source_id=#{@source_id}: natural key (#{lookup.keys.join(", ")}) matches more than one destination row"
        end
      end
    end
  end
end
