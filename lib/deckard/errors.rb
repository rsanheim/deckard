# frozen_string_literal: true

module Deckard
  def self.error_detail(error)
    detail = error.message.to_s.lines.first.to_s.strip
    detail.empty? ? "(no message)" : detail
  end

  class Error < StandardError; end

  class ConfigurationError < Error; end

  class DumpError < Error; end

  class OutputError < DumpError; end

  class LoadError < Error; end

  class UnsupportedAssociation < DumpError; end

  class UnresolvedReference < LoadError; end

  class InvalidStream < LoadError; end

  class InsertError < LoadError; end
end
