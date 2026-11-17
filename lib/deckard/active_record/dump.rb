# frozen_string_literal: true

module Deckard
  module ActiveRecord
    # Dumps one record by the root's plan (docs/traversal.md), and the records
    # it reaches by the same plan.
    class Dump
      # Stored generated columns (GENERATED ALWAYS AS ... STORED) are never
      # dumped: the destination database computes them, and PostgreSQL
      # rejects explicit inserts into them. Computed once per model class.
      GENERATED_COLUMNS = Hash.new do |cache, model|
        cache[model] = model.columns.select(&:virtual?).map(&:name)
      end

      def self.source_id(record)
        if record.class.primary_key.is_a?(Array)
          raise DumpError, "#{record.class} has a composite primary key, which deckard does not support"
        end
        record.id
      end

      # Dumps sibling records the plan owns, then each planned collection of
      # the ones this visit walked: one batched query per class and
      # collection, rather than one per record.
      def self.dump_owned(records, dumper, plan)
        walked = records.select { |record| new(record, dumper, plan, owned: true).call }
        walked.group_by(&:class).each do |model, owners|
          entry = plan.for(model)
          (entry.extra_associations - entry.omitted_associations).each do |name|
            reflection = model.reflect_on_association(name)
            next unless reflection.collection?

            # A scope that takes the owner cannot be shared across owners.
            relations = if reflection.scope&.arity&.positive?
              owners.map { |owner| owner.public_send(name) }
            else
              keys = owners.map { |owner| owner[reflection.active_record_primary_key] }.compact
              [owners.first.association(name).scope.unscope(where: reflection.foreign_key).where(reflection.foreign_key => keys)]
            end
            relations.each { |relation| relation.find_in_batches { |batch| dump_owned(batch, dumper, plan) } }
          end
        end
      end

      def initialize(record, dumper, plan, owned:)
        @record = record
        @model = record.class
        @source_id = self.class.source_id(record)
        @dumper = dumper
        @plan = plan
        @owned = owned
        @entry = plan.for(@model)
      end

      # Dumps the record and, when owned, its singular owned records. Planned
      # collections are left to dump_owned. True when this visit walked it.
      def call
        walked = false
        @dumper.visit(@model.name, @source_id, walk: @owned) do
          attributes = @record.attributes.except(*GENERATED_COLUMNS[@model], *@entry.omitted_fields)
          dump_belongs_to(attributes)
          @dumper.write(@model.name, @source_id, attributes, @entry.match_key)
          next unless @owned

          walked = true
          owned = @model.reflect_on_all_associations(:has_one).map(&:name) | @entry.extra_associations
          (owned - @entry.omitted_associations).each do |name|
            next if @model.reflect_on_association(name).collection?

            self.class.dump_owned(Array(@record.public_send(name)), @dumper, @plan)
          end
        end
        walked
      end

      private

      def dump_belongs_to(attributes)
        @model.reflect_on_all_associations(:belongs_to).each do |reflection|
          foreign_key = reflection.foreign_key.to_s
          next if @entry.omitted_associations.include?(reflection.name)
          next if encode_dumped_parent(attributes, reflection, foreign_key)

          referenced = @record.public_send(reflection.name)
          next if referenced.nil?

          self.class.new(referenced, @dumper, @plan, owned: false).call
          referenced_id = self.class.source_id(referenced)
          unless @dumper.dumped?(referenced.class.name, referenced_id)
            raise DumpError,
              "dependency cycle detected: #{@model}(#{@source_id}).#{reflection.name} " \
              "references #{referenced.class.name}(#{referenced_id}), which cannot be emitted first"
          end
          next if @entry.omitted_fields.include?(foreign_key)
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

        attributes[foreign_key] = [:id, reflection.klass.name, value] unless @entry.omitted_fields.include?(foreign_key)
        true
      end
    end
  end
end
