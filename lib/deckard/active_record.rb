# frozen_string_literal: true

module Deckard
  # Implements the replicant protocol for ActiveRecord models. Included into
  # ActiveRecord::Base when ActiveRecord loads (see lib/deckard.rb). Models
  # gain exactly three methods: the `replicate` configuration DSL,
  # `dump_replicant`, and `load_replicant`. Traversal and loading live in
  # the plain objects Dump (lib/deckard/active_record/dump.rb) and Load
  # (lib/deckard/active_record/load.rb) so nothing else lands in the model
  # namespace.
  module ActiveRecord
    def self.included(base)
      base.extend ClassMethods
    end

    def dump_replicant(dumper, options = {})
      Dump.new(self, dumper, options).call
    end

    module ClassMethods
      # The `replicate do ... end` DSL: this model's replication plan.
      def replicate(&block)
        ModelConfig.declare(name, &block)
      end

      # Load one streamed replicant: reuse an existing row when a natural key
      # matches, otherwise insert a new row with a destination-generated
      # primary key. Both paths bypass validations and callbacks.
      def load_replicant(type, source_id, attributes)
        Load.new(self, type, source_id, attributes).call
      end
    end
  end
end
