# frozen_string_literal: true

require "json"

module Deckard
  # Renders a plan's #to_h for people (text) or tools (json). Rendering
  # never looks at the plan itself, so a new format is a new method here.
  module PlanReport
    FORMATS = %w[text json].freeze

    LINES = {
      "associations" => "associations",
      "natural_key" => "natural key",
      "omit_fields" => "omit fields",
      "omit_associations" => "omit associations"
    }.freeze

    def self.render(plan, format)
      case format
      when "text" then text(plan)
      when "json" then "#{JSON.pretty_generate(plan)}\n"
      else raise ArgumentError, "unknown plan format #{format.inspect}; use one of #{FORMATS.join(", ")}"
      end
    end

    def self.text(plan)
      blocks = plan["entries"].map do |entry|
        lines = LINES.filter_map do |key, label|
          "  #{label.ljust(18)}#{entry[key].join(", ")}" unless entry[key].empty?
        end
        [entry["model"], *lines].join("\n")
      end
      "#{blocks.join("\n\n")}\n"
    end
  end
end
