# frozen_string_literal: true

module Deckard
  # Implements the replicant protocol for ActiveRecord models. Included into
  # ActiveRecord::Base when ActiveRecord loads (see lib/deckard.rb).
  #
  # Traversal order: belongs_to associations, the record itself, then has_one
  # associations, so a record appears after the records its foreign keys
  # reference. has_many associations are never followed automatically.
  module ActiveRecord
    def self.included(base)
      base.extend ClassMethods
    end

    def dump_replicant(dumper, options = {})
      dumper.once(self.class.name, replicant_source_id) do
        attributes = self.attributes.dup
        dump_belongs_to_replicants(dumper, attributes, options)
        dumper.write(self.class.name, replicant_source_id, attributes, self)
        dump_has_one_replicants(dumper, options)
      end
    end

    private

    def replicant_source_id
      if self.class.primary_key.is_a?(Array)
        raise DumpError, "#{self.class} has a composite primary key, which deckard does not support"
      end
      id
    end

    def dump_belongs_to_replicants(dumper, attributes, options)
      self.class.reflect_on_all_associations(:belongs_to).each do |reflection|
        if reflection.polymorphic?
          next if public_send(reflection.name).nil?
          raise UnsupportedAssociation,
            "#{self.class}(#{replicant_source_id}).#{reflection.name} is a polymorphic belongs_to association"
        end

        referenced = public_send(reflection.name)
        next if referenced.nil?

        dumper.dump(referenced, options)
        attributes[reflection.foreign_key.to_s] =
          [:id, referenced.class.name, referenced.send(:replicant_source_id)]
      end
    end

    def dump_has_one_replicants(dumper, options)
      self.class.reflect_on_all_associations(:has_one).each do |reflection|
        dependent = public_send(reflection.name)
        dumper.dump(dependent, options) if dependent
      end
    end

    module ClassMethods
      # Insert a new row for the streamed replicant, bypassing validations
      # and callbacks, with a destination-generated primary key.
      def load_replicant(type, source_id, attributes)
        if primary_key.is_a?(Array)
          raise LoadError, "#{name} has a composite primary key, which deckard does not support"
        end

        row = attributes.except(primary_key)
        begin
          result = insert_all!([row], returning: [primary_key])
          destination_id = result.rows.first.first
          [destination_id, find(destination_id)]
        rescue ::ActiveRecord::ActiveRecordError => e
          raise InsertError,
            "#{type} source_id=#{source_id} could not be inserted: #{e.message.lines.first.strip}"
        end
      end
    end
  end
end
