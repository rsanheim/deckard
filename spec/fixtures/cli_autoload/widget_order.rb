# frozen_string_literal: true

require "active_record"

# A plan the CLI can print and validate without a database: nothing here
# names an attribute, and the one association exists on the class.
class WidgetOrder < ActiveRecord::Base
  replicate do
    omit_associations :warehouse
    model "WidgetLine" do
      associations :adjustments
      omit_associations :tax
    end
  end
end
