# frozen_string_literal: true

require "active_record"

# A plan naming a model that does not exist. Loaded only through eager
# loading, so the CLI must both eager load and validate to reject it.
class LazyOrder < ActiveRecord::Base
  replicate do
    model "Refund" do
      match_by :number
    end
  end
end
