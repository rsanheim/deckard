# frozen_string_literal: true

require "active_record"

class WidgetLine < ActiveRecord::Base
  belongs_to :tax
  has_many :adjustments
end
