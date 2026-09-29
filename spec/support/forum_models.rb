# frozen_string_literal: true

require "active_record"

# The forum models behind the gem's ActiveRecord specs, backed by the schema
# in spec/db/schema.rb. Defining them touches no database. Each replicate
# block is the whole plan for dumps rooted at that model.

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

  # An author's forum activity, matched on the destination by username;
  # the one profile and the emails already present are updated in place.
  replicate do
    natural_key :username
    associations :posts, :author_emails, :reactions, :donations, :attachments
    model "Profile" do
      natural_key :author_id
    end
    model "AuthorEmail" do
      natural_key :author_id, :address
    end
    model "Post" do
      associations :comments
    end
    model "Comment" do
      associations :replies
    end
    model "Category" do
      natural_key :slug
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

  replicate do
    natural_key :author_id, :address
    model "Author" do
      natural_key :username
    end
  end
end

class Category < ActiveRecord::Base
  has_many :posts

  replicate do
    natural_key :slug
    omit_fields :moderator_notes
  end
end

class AnnouncementCategory < Category
end

# Deliberately broken: its plan names an association that does not exist,
# which must raise at dump time, and a model that does not exist, which
# whole-plan validation must report.
class MisconfiguredCategory < ActiveRecord::Base
  self.table_name = "categories"

  replicate do
    associations :moderators
    model "Moderator" do
      natural_key :login
    end
  end
end

# Deliberately unsupported plans, over the authors table: a selected
# has_and_belongs_to_many and a selected has_many :through.
class Bookmarker < ActiveRecord::Base
  self.table_name = "authors"
  has_and_belongs_to_many :bookmarked_posts,
    class_name: "Post",
    join_table: "bookmarks",
    foreign_key: "author_id",
    association_foreign_key: "post_id"

  replicate do
    associations :bookmarked_posts
  end
end

class Commenter < ActiveRecord::Base
  self.table_name = "authors"
  has_many :comments, foreign_key: :author_id
  has_many :commented_posts, through: :comments, source: :post

  replicate do
    associations :commented_posts
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

  # A post and its comment threads. Comment is named before its class is
  # defined, Category after; Category's own plan is not consulted here.
  replicate do
    associations :comments
    model "Comment" do
      associations :replies
    end
    model "Author" do
      natural_key :username
    end
    model "Profile" do
      natural_key :author_id
    end
    model "Category" do
      natural_key :slug
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

  # A comment brings the whole thread on its post.
  replicate do
    model "Post" do
      associations :comments
    end
    model "Author" do
      natural_key :username
    end
  end
end

class Tag < ActiveRecord::Base
  has_many :post_tags
  has_many :posts, through: :post_tags

  replicate do
    natural_key :name
  end
end

class PostTag < ActiveRecord::Base
  belongs_to :post
  belongs_to :tag

  # The tag is left behind: its foreign key travels as-is.
  replicate do
    omit_associations :tag
    model "Author" do
      natural_key :username
    end
  end
end

class Reaction < ActiveRecord::Base
  belongs_to :author
  belongs_to :reactable, polymorphic: true

  # The target is left behind: its polymorphic foreign key travels as-is.
  replicate do
    omit_associations :reactable
    model "Author" do
      natural_key :username
    end
  end
end

# A mention names its author by username, not by id: the foreign key targets
# a non-primary-key column and must be copied as-is rather than remapped.
class Mention < ActiveRecord::Base
  belongs_to :comment
  belongs_to :author, primary_key: :username, foreign_key: :mentioned_username

  replicate do
    model "Author" do
      natural_key :username
    end
  end
end

# UUID primary keys, database-generated.
class Attachment < ActiveRecord::Base
  belongs_to :author
  has_many :variants, class_name: "AttachmentVariant"

  replicate do
    associations :variants
    model "Author" do
      natural_key :username
    end
  end
end

class AttachmentVariant < ActiveRecord::Base
  belongs_to :attachment

  # A variant brings its siblings: Variant -> Attachment -> variants.
  replicate do
    model "Attachment" do
      associations :variants
    end
    model "Author" do
      natural_key :username
    end
  end
end

class Donation < ActiveRecord::Base
  belongs_to :author
  belongs_to :post, optional: true

  # The post travels, but the donation's link to it does not.
  replicate do
    omit_fields :post_id
    model "Author" do
      natural_key :username
    end
  end
end

# Composite primary key (derived from the schema): unsupported, must raise.
class PostView < ActiveRecord::Base
  belongs_to :post
end
