# frozen_string_literal: true

require "active_record"

# A plan naming a model that does not exist. Loaded only through eager
# loading, so the CLI must both eager load and validate to reject it.
class LazyOrder < ActiveRecord::Base
  replicate do
    model "Refund" do
      natural_key :number
    end
  end
end
