# frozen_string_literal: true

require "active_record"

# A plan the CLI can print and validate without a database: nothing here
# names an attribute, and every named association exists on its class.
class WidgetOrder < ActiveRecord::Base
  belongs_to :warehouse

  replicate do
    omit_associations :warehouse
    model "WidgetLine" do
      associations :adjustments
      omit_associations :tax
    end
  end
end
