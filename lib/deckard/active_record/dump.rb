# frozen_string_literal: true

module Deckard
  module ActiveRecord
    # Dumps one record and its dependencies by the root's plan. Traversal
    # order: belongs_to associations, the record itself, has_one
    # associations, then the associations the plan names for this class.
    # has_many associations are never followed automatically. Records
    # reached from this one are dumped by the same plan.
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

      def initialize(record, dumper, plan)
        @record = record
        @model = record.class
        @source_id = self.class.source_id(record)
        @dumper = dumper
        @plan = plan
        @config = plan.for(@model)
      end

      def call
        @dumper.once(@model.name, @source_id) do
          @config.validate!(@model)
          attributes = @record.attributes.except(*GENERATED_COLUMNS[@model], *@config.omitted_fields.map(&:to_s))
          dump_belongs_to(attributes)
          @dumper.write(@model.name, @source_id, attributes, @config.natural_key_attributes.map(&:to_s))
          dump_has_one
          dump_configured
        end
      end

      private

      def dump_belongs_to(attributes)
        @model.reflect_on_all_associations(:belongs_to).each do |reflection|
          foreign_key = reflection.foreign_key.to_s
          next if @config.omitted_associations.include?(reflection.name)
          next if encode_dumped_parent(attributes, reflection, foreign_key)

          referenced = @record.public_send(reflection.name)
          next if referenced.nil?

          dump_related(referenced)
          referenced_id = self.class.source_id(referenced)
          unless @dumper.dumped?(referenced.class.name, referenced_id)
            raise DumpError,
              "dependency cycle detected: #{@model}(#{@source_id}).#{reflection.name} " \
              "references #{referenced.class.name}(#{referenced_id}), which cannot be emitted first"
          end
          next if @config.omitted_fields.include?(foreign_key.to_sym)
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

        attributes[foreign_key] = [:id, reflection.klass.name, value] unless @config.omitted_fields.include?(foreign_key.to_sym)
        true
      end

      def dump_has_one
        @model.reflect_on_all_associations(:has_one).each do |reflection|
          next if @config.omitted_associations.include?(reflection.name)
          dump_related(@record.public_send(reflection.name))
        end
      end

      def dump_configured
        @config.extra_associations.each do |name|
          next if @config.omitted_associations.include?(name)
          dump_related(@record.public_send(name))
        end
      end

      # One record or a collection, dumped by this root's plan.
      def dump_related(associated)
        return if associated.nil?
        return self.class.new(associated, @dumper, @plan).call unless associated.respond_to?(:find_each)

        associated.find_each { |record| self.class.new(record, @dumper, @plan).call }
      end
    end
  end
end
