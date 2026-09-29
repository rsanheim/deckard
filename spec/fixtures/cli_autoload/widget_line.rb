# frozen_string_literal: true

require "active_record"

class WidgetLine < ActiveRecord::Base
  has_many :adjustments
end
