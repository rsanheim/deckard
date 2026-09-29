# frozen_string_literal: true

module Deckard
  module ActiveRecord
    # Loads one replicant tuple into a model's table.
    class Load
      def initialize(model, type, source_id, attributes, natural_key)
        @model = model
        @type = type
        @source_id = source_id
        @attributes = attributes
        @natural_key = natural_key
      end

      def call
        if @model.primary_key.is_a?(Array)
          raise LoadError, "#{@model.name} has a composite primary key, which deckard does not support"
        end

        @natural_key.empty? ? insert : load_by_natural_key
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

      def load_by_natural_key
        lookup = @attributes.slice(*@natural_key)
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
