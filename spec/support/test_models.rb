# frozen_string_literal: true

require "active_record"

# ActiveRecord models for the deckard specs, backed by the schema in
# DeckardTestDatabase. Defining them touches no database.

class Author < ActiveRecord::Base
  has_one :profile
  has_many :posts

  # Both guards prove the loader's bypass: any load that runs them fails.
  before_save { self.class.callbacks_fired << name }
  validate { errors.add(:base, "always invalid") }

  def self.callbacks_fired
    @callbacks_fired ||= []
  end
end

class Profile < ActiveRecord::Base
  belongs_to :author
end

class Post < ActiveRecord::Base
  belongs_to :author
  has_many :comments
end

class Comment < ActiveRecord::Base
  belongs_to :post
  belongs_to :author
end

class Payment < ActiveRecord::Base
  belongs_to :billable, polymorphic: true, optional: true
end

class CycleA < ActiveRecord::Base
  belongs_to :cycle_b, optional: true
end

class CycleB < ActiveRecord::Base
  belongs_to :cycle_a, optional: true
end
