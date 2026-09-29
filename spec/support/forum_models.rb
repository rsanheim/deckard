# frozen_string_literal: true

require "active_record"

# The forum models behind the gem's ActiveRecord specs, backed by the schema
# in spec/db/schema.rb. Defining them touches no database.

class Author < ActiveRecord::Base
  has_one :profile
  has_many :posts
  has_many :comments
  has_many :author_emails
  has_many :reactions
  has_many :donations
  has_many :attachments
  has_many :commented_posts, through: :comments, source: :post
  has_and_belongs_to_many :bookmarked_posts,
    class_name: "Post",
    join_table: "bookmarks",
    association_foreign_key: "post_id"
  # Authors belong to their featured post and posts belong to their author:
  # a dependency cycle whenever featured_post_id is set.
  belongs_to :featured_post, class_name: "Post", optional: true

  enum :role, {member: 0, moderator: 1, admin: 2}
  encrypts :private_notes

  # These guards let the loader specs prove that callbacks and validations
  # are bypassed without making every Author fixture invalid.
  before_save { self.class.callbacks_fired << username }
  validate { errors.add(:base, "invalid replicant") if name == "Invalid Replicant" }

  def self.callbacks_fired
    @callbacks_fired ||= []
  end

  # An author is a dump root: the plan for an author's activity, including
  # the models it reaches, lives here. Re-importing an author updates the
  # one profile and the emails already present.
  replicate do
    natural_key :username
    model "Profile" do
      natural_key :author_id
    end
    model "AuthorEmail" do
      natural_key :author_id, :address
    end
    model "Attachment" do
      associations :variants
    end
  end
end

class Profile < ActiveRecord::Base
  belongs_to :author
end

class AuthorEmail < ActiveRecord::Base
  belongs_to :author
end

class Category < ActiveRecord::Base
  has_many :posts
end

class AnnouncementCategory < Category
end

# Deliberately broken: its replicate block names an association that does
# not exist, which must raise at dump time, and declares configuration for
# a model that does not exist, which whole-configuration validation must
# report.
class MisconfiguredCategory < ActiveRecord::Base
  self.table_name = "categories"

  replicate do
    associations :moderators
    model "Moderator" do
      natural_key :login
    end
  end
end

class Post < ActiveRecord::Base
  belongs_to :author
  belongs_to :category, optional: true
  has_many :comments
  has_many :post_tags
  has_many :tags, through: :post_tags
  has_many :reactions, as: :reactable
  has_many :donations
  has_many :post_views
  has_and_belongs_to_many :bookmarking_authors,
    class_name: "Author",
    join_table: "bookmarks",
    association_foreign_key: "author_id"

  # A post is a dump root: the plan for a post and the models a post dump
  # reaches lives here. Comment is named before its class is defined,
  # Category after.
  replicate do
    associations :comments
    model "Comment" do
      associations :replies
    end
    model "Category" do
      natural_key :slug
      omit_fields :moderator_notes
    end
    model "Tag" do
      natural_key :name
    end
  end
end

# Threaded: a reply belongs to its parent comment.
class Comment < ActiveRecord::Base
  belongs_to :post
  belongs_to :author
  belongs_to :parent, class_name: "Comment", optional: true
  has_many :replies, class_name: "Comment", foreign_key: :parent_id
  has_many :mentions
  has_many :reactions, as: :reactable
end

class Tag < ActiveRecord::Base
  has_many :post_tags
  has_many :posts, through: :post_tags
end

class PostTag < ActiveRecord::Base
  belongs_to :post
  belongs_to :tag
end

class Reaction < ActiveRecord::Base
  belongs_to :author
  belongs_to :reactable, polymorphic: true
end

# A mention names its author by username, not by id: the foreign key targets
# a non-primary-key column and must be copied as-is rather than remapped.
class Mention < ActiveRecord::Base
  belongs_to :comment
  belongs_to :author, primary_key: :username, foreign_key: :mentioned_username
end

# UUID primary keys, database-generated.
class Attachment < ActiveRecord::Base
  belongs_to :author
  has_many :variants, class_name: "AttachmentVariant"
end

class AttachmentVariant < ActiveRecord::Base
  belongs_to :attachment
end

class Donation < ActiveRecord::Base
  belongs_to :author
  belongs_to :post, optional: true
end

# Composite primary key (derived from the schema): unsupported, must raise.
class PostView < ActiveRecord::Base
  belongs_to :post
end
