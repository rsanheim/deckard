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

    # Records reached from this one are dumped by its plan directly, so an
    # override of this method applies to roots only.
    def dump_replicant(dumper)
      Dump.new(self, dumper, ModelConfig.plan_for(self.class), owned: true).call
    end

    module ClassMethods
      # The `replicate do ... end` DSL: the plan for dumps rooted here.
      def replicate(&block)
        ModelConfig.declare(name, &block)
      end

      # Load one streamed replicant: reuse an existing row when its natural
      # key matches, otherwise insert a new row with a destination-generated
      # primary key. Both paths bypass validations and callbacks.
      def load_replicant(type, source_id, attributes, natural_key)
        Load.new(self, type, source_id, attributes, natural_key).call
      end
    end
  end
end
