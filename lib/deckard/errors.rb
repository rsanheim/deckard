# frozen_string_literal: true

module Deckard
  class Error < StandardError; end

  class DumpError < Error; end

  class LoadError < Error; end

  class UnsupportedAssociation < DumpError; end

  class UnresolvedReference < LoadError; end

  class InvalidStream < LoadError; end

  class InsertError < LoadError; end
end
