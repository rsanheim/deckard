# frozen_string_literal: true

module Deckard
  module ActiveRecord
    # Loads one replicant tuple into a model's table.
    class Load
      def initialize(model, type, source_id, attributes, match_key)
        @model = model
        @type = type
        @source_id = source_id
        @attributes = attributes
        @match_key = match_key
      end

      def call
        if @model.primary_key.is_a?(Array)
          raise LoadError, "#{@model.name} has a composite primary key, which deckard does not support"
        end

        @match_key.empty? ? insert : load_by_match_key
      end

      private

      # `because` says what led to the insert when it was not the only path,
      # so a failure names the match key that matched nothing.
      def insert(because = "")
        # An auto-populated primary key is left to the destination database.
        auto_populated = @model.columns_hash[@model.primary_key].auto_populated?
        attributes = auto_populated ? @attributes.except(@model.primary_key) : @attributes
        result = @model.insert_all!([attributes], returning: [@model.primary_key])
        destination_id = result.rows.first.first
        [destination_id, @model.find(destination_id)]
      rescue ::ActiveRecord::ActiveRecordError => e
        raise InsertError,
          "#{@type} source_id=#{@source_id} #{because}could not be inserted: #{Deckard.error_detail(e)}"
      end

      def load_by_match_key
        lookup = @attributes.slice(*@match_key)
        matches = @model.where(lookup).limit(2).to_a

        case matches.size
        when 0
          insert("matched no destination row by match key (#{lookup.keys.join(", ")}) and ")
        when 1
          record = matches.first
          begin
            record.update_columns(@attributes.except(@model.primary_key))
          rescue ::ActiveRecord::ActiveRecordError => e
            raise InsertError,
              "#{@type} source_id=#{@source_id} could not be updated via match key: #{Deckard.error_detail(e)}"
          end
          [record.id, record]
        else
          raise LoadError,
            "#{@type} source_id=#{@source_id}: match key (#{lookup.keys.join(", ")}) matches more than one destination row"
        end
      end
    end
  end
end
