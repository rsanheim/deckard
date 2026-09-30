# frozen_string_literal: true

require "active_record"

# The forum models behind the gem's ActiveRecord specs, backed by the schema
# in spec/db/schema.rb. Defining them touches no database. Each replicate
# block is the whole plan for dumps rooted at that model; plans that only
# name Author's natural key exist so round-trip specs, which load back into
# the source database, reuse authors instead of violating the username index.

class Author < ActiveRecord::Base
  has_one :profile
  has_many :posts
  has_many :author_emails
  has_many :reactions
  has_many :donations
  has_many :attachments
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

  # An author's forum activity. Reactions come before posts so an author
  # who reacts to their own post reaches it as a dependency first and owns
  # it later. There is no Reaction entry, so a reaction's target is followed
  # here even though Reaction's own plan omits it.
  replicate do
    natural_key :username
    associations :reactions, :posts, :author_emails, :donations, :attachments
    natural_keys "Profile" => :author_id, "AuthorEmail" => [:author_id, :address], "Category" => :slug
    model "Post" do
      associations :comments
    end
    model "Comment" do
      associations :replies
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
    natural_keys "Author" => :username
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

# Deliberately broken: names an association and an attribute the model
# lacks, a model that does not exist, an unsupported association on a
# reached class, and a natural key given twice for one class. Whole-plan
# validation must report all of it.
class MisconfiguredCategory < ActiveRecord::Base
  self.table_name = "categories"

  replicate do
    associations :moderators
    natural_key :handle
    natural_keys "Moderator" => :login, "Post" => :title
    model "Post" do
      natural_key :title
      associations :tags
    end
  end
end

# An author matched by username whose name never travels, over the authors
# table: on a destination without that author, the insert has no name to
# give and fails.
class Visitor < ActiveRecord::Base
  self.table_name = "authors"

  replicate do
    natural_key :username
    omit_fields :name
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

  # A post and its comment threads. Authors and the category are reached by
  # reference: their own plans are never consulted here, so a post dump
  # carries moderator_notes while a category dump omits them.
  replicate do
    associations :comments
    natural_keys "Author" => :username, "Category" => :slug
    model "Comment" do
      associations :replies, :mentions
    end
    model "Author" do
      omit_fields :private_notes, :api_token
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

  replicate do
    natural_keys "Author" => :username
  end
end

class Tag < ActiveRecord::Base
  has_many :post_tags

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
    natural_keys "Author" => :username
  end
end

class Reaction < ActiveRecord::Base
  belongs_to :author
  belongs_to :reactable, polymorphic: true

  # The target is left behind: its polymorphic foreign key travels as-is.
  replicate do
    omit_associations :reactable
    natural_keys "Author" => :username
  end
end

# A mention names its author by username, not by id: the foreign key targets
# a non-primary-key column and must be copied as-is rather than remapped.
class Mention < ActiveRecord::Base
  belongs_to :comment
  belongs_to :author, primary_key: :username, foreign_key: :mentioned_username

  replicate do
    natural_keys "Author" => :username
  end
end

# UUID primary keys, database-generated.
class Attachment < ActiveRecord::Base
  belongs_to :author
  has_many :variants, class_name: "AttachmentVariant"

  replicate do
    associations :variants
    natural_keys "Author" => :username
  end
end

class AttachmentVariant < ActiveRecord::Base
  belongs_to :attachment

  replicate do
    natural_keys "Author" => :username
  end
end

class Donation < ActiveRecord::Base
  belongs_to :author
  belongs_to :post, optional: true

  # The post travels, but the donation's link to it does not.
  replicate do
    omit_fields :post_id
    natural_keys "Author" => :username
  end
end

# Composite primary key (derived from the schema): unsupported, must raise.
class PostView < ActiveRecord::Base
  belongs_to :post
end
