# frozen_string_literal: true

module Deckard
  # Implements the replicant protocol for ActiveRecord models. Included into
  # ActiveRecord::Base when ActiveRecord loads (see lib/deckard.rb).
  #
  # Traversal order: belongs_to associations, the record itself, has_one
  # associations, then associations configured via `replicate` or per-dump
  # options. has_many associations are never followed automatically.
  module ActiveRecord
    def self.included(base)
      base.extend ClassMethods
    end

    def dump_replicant(dumper, options = {})
      dumper.once(self.class.name, replicant_source_id) do
        omissions = replicant_omissions(options)
        attributes = self.attributes.except(*self.class.deckard_generated_columns, *omissions.map(&:to_s))
        dump_belongs_to_replicants(dumper, attributes, omissions, options)
        dumper.write(self.class.name, replicant_source_id, attributes, self)
        dump_has_one_replicants(dumper, omissions, options)
        dump_configured_replicants(dumper, omissions, options)
      end
    end

    private

    def replicant_source_id
      if self.class.primary_key.is_a?(Array)
        raise DumpError, "#{self.class} has a composite primary key, which deckard does not support"
      end
      id
    end

    # Model-configured omissions plus per-dump omit: names.
    def replicant_omissions(options)
      self.class.deckard_model_config.omissions + Array(options[:omit]).map(&:to_sym)
    end

    def dump_belongs_to_replicants(dumper, attributes, omissions, options)
      self.class.reflect_on_all_associations(:belongs_to).each do |reflection|
        foreign_key = reflection.foreign_key.to_s
        if omissions.include?(reflection.name) || omissions.include?(foreign_key.to_sym)
          attributes.delete(foreign_key)
          next
        end

        if reflection.polymorphic?
          next if public_send(reflection.name).nil?
          raise UnsupportedAssociation,
            "#{self.class}(#{replicant_source_id}).#{reflection.name} is a polymorphic belongs_to association"
        end

        referenced = public_send(reflection.name)
        next if referenced.nil?

        dumper.dump(referenced, options)
        referenced_id = referenced.send(:replicant_source_id)
        unless dumper.dumped?(referenced.class.name, referenced_id)
          raise DumpError,
            "dependency cycle detected: #{self.class}(#{replicant_source_id}).#{reflection.name} " \
            "references #{referenced.class.name}(#{referenced_id}), which cannot be emitted first"
        end
        attributes[foreign_key] = [:id, referenced.class.name, referenced_id]
      end
    end

    def dump_has_one_replicants(dumper, omissions, options)
      self.class.reflect_on_all_associations(:has_one).each do |reflection|
        next if omissions.include?(reflection.name)
        dependent = public_send(reflection.name)
        dumper.dump(dependent, options) if dependent
      end
    end

    # Associations named in the model's `replicate` block must exist; names
    # passed per-dump are skipped on classes that lack them, because options
    # cascade to every record reached in the traversal.
    def dump_configured_replicants(dumper, omissions, options)
      configured = self.class.deckard_model_config.extra_associations
      configured.each do |name|
        next if omissions.include?(name)
        unless self.class.reflect_on_association(name)
          raise DumpError, "#{self.class} names #{name.inspect} in its replicate block, but no such association exists"
        end
        dump_association(dumper, name, options)
      end

      Array(options[:associations]).map(&:to_sym).each do |name|
        next if omissions.include?(name) || configured.include?(name)
        next unless self.class.reflect_on_association(name)
        dump_association(dumper, name, options)
      end
    end

    def dump_association(dumper, name, options)
      associated = public_send(name)
      dumper.dump(associated, options) if associated
    end

    module ClassMethods
      # The `replicate do ... end` model DSL.
      def replicate(&block)
        deckard_model_config.instance_eval(&block)
      end

      def deckard_model_config
        @deckard_model_config ||= ModelConfig.new(
          superclass.respond_to?(:deckard_model_config) ? superclass.deckard_model_config : nil
        )
      end

      # Stored generated columns (GENERATED ALWAYS AS ... STORED) are never
      # dumped: the destination database computes them, and PostgreSQL
      # rejects explicit inserts into them.
      def deckard_generated_columns
        @deckard_generated_columns ||=
          columns.select { |column| column.respond_to?(:virtual?) && column.virtual? }.map(&:name)
      end

      # Load one streamed replicant: reuse an existing row when a natural key
      # matches, otherwise insert a new row with a destination-generated
      # primary key. Both paths bypass validations and callbacks.
      def load_replicant(type, source_id, attributes)
        if primary_key.is_a?(Array)
          raise LoadError, "#{name} has a composite primary key, which deckard does not support"
        end

        key = deckard_model_config.natural_key_attributes
        if key.empty?
          insert_replicant(type, source_id, attributes)
        else
          load_replicant_by_natural_key(type, source_id, attributes, key)
        end
      end

      private

      def insert_replicant(type, source_id, attributes)
        result = insert_all!([attributes.except(primary_key)], returning: [primary_key])
        destination_id = result.rows.first.first
        [destination_id, find(destination_id)]
      rescue ::ActiveRecord::ActiveRecordError => e
        raise InsertError,
          "#{type} source_id=#{source_id} could not be inserted: #{e.message.lines.first.strip}"
      end

      def load_replicant_by_natural_key(type, source_id, attributes, key)
        lookup = key.to_h { |attribute| [attribute.to_s, attributes[attribute.to_s]] }
        matches = where(lookup).limit(2).to_a

        case matches.size
        when 0
          insert_replicant(type, source_id, attributes)
        when 1
          record = matches.first
          begin
            record.update_columns(attributes.except(primary_key))
          rescue ::ActiveRecord::ActiveRecordError => e
            raise InsertError,
              "#{type} source_id=#{source_id} could not be updated via natural key: #{e.message.lines.first.strip}"
          end
          [record.id, record]
        else
          raise LoadError,
            "#{type} source_id=#{source_id}: natural key (#{lookup.keys.join(", ")}) matches more than one destination row"
        end
      end
    end
  end
end
