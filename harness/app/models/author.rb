class Author < ApplicationRecord
  has_one :profile
  has_many :posts
  has_many :comments

  encrypts :private_notes

  # These guards prove Deckard's callback/validation bypass: any load that
  # runs them fails loudly. Seeding sets DECKARD_SEED to get past them.
  before_create :forbid_callbacks
  validate :forbid_validations

  private

  def forbid_callbacks
    return if ENV["DECKARD_SEED"]
    raise "Author before_create callback ran - deckard must bypass callbacks"
  end

  def forbid_validations
    return if ENV["DECKARD_SEED"]
    errors.add(:base, "Author validation ran - deckard must bypass validations")
  end
end
