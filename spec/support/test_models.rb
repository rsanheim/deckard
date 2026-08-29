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

class Reader < ActiveRecord::Base
  has_many :reader_emails

  # Guard proving the natural-key update path also bypasses callbacks.
  before_save { self.class.callbacks_fired << login }

  def self.callbacks_fired
    @callbacks_fired ||= []
  end

  replicate do
    natural_key :login
  end
end

class ReaderEmail < ActiveRecord::Base
  belongs_to :reader

  replicate do
    natural_key :reader_id, :email
  end
end

class Library < ActiveRecord::Base
  has_many :books

  replicate do
    associations :books
    omit :secret
  end
end

class SpecialLibrary < Library
end

class Book < ActiveRecord::Base
  belongs_to :library, optional: true
end

# Deliberately broken: its replicate block names an association that does
# not exist, which must raise at dump time.
class MisconfiguredLibrary < ActiveRecord::Base
  self.table_name = "libraries"

  replicate do
    associations :branches
  end
end

# UUID primary keys, database-generated.
class Ship < ActiveRecord::Base
  has_many :cargos
end

class Cargo < ActiveRecord::Base
  belongs_to :ship
end

# Self-referential belongs_to with class_name and a non-conventional
# foreign key name.
class Employee < ActiveRecord::Base
  belongs_to :manager, class_name: "Employee", optional: true
end

# A spread of PostgreSQL column types that must survive dump and load.
class Artifact < ActiveRecord::Base
  enum :status, {draft: 0, live: 1}
end

# Composite primary key (derived from the schema): unsupported, must raise.
class Itinerary < ActiveRecord::Base
end
