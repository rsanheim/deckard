# The forum schema behind the gem's ActiveRecord specs. One coherent domain
# whose natural features carry every shape deckard must handle: the
# supported associations, the ones that must fail clearly, natural keys, a
# non-primary-key foreign key, STI, UUID keys, a composite key, a
# dependency cycle, and a spread of PostgreSQL column types.
class CreateForum < ActiveRecord::Migration[8.1]
  def change
    create_enum :post_status, %w[draft published]

    create_table :authors do |t|
      t.string :username, null: false
      t.string :name, null: false
      t.string :email
      t.text :bio
      t.string :location
      t.string :website
      t.boolean :verified, null: false, default: false
      t.integer :role, null: false, default: 0
      t.jsonb :settings
      t.date :birthday
      t.uuid :api_token
      t.binary :avatar
      t.text :private_notes
      t.datetime :joined_at
      # A required belongs_to back to posts, which belong to authors: a true
      # dependency cycle when set. Foreign key added after posts exists.
      t.bigint :featured_post_id
      t.timestamps
    end
    add_index :authors, :username, unique: true

    create_table :profiles do |t|
      t.references :author, null: false, foreign_key: true, index: {unique: true}
      t.text :bio
      t.timestamps
    end

    create_table :author_emails do |t|
      t.references :author, null: false, foreign_key: true
      t.string :address, null: false
      t.string :label
      t.datetime :verified_at
    end
    add_index :author_emails, [:author_id, :address], unique: true

    create_table :categories do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :type
      t.text :description
      t.text :moderator_notes
    end
    add_index :categories, :slug, unique: true

    create_table :posts do |t|
      t.references :author, null: false, foreign_key: true
      t.references :category, foreign_key: true
      t.string :title, null: false
      t.text :body
      t.enum :status, enum_type: :post_status, null: false, default: "draft"
      t.string :visibility, null: false, default: "public"
      t.string :language
      t.boolean :sensitive, null: false, default: false
      t.string :keywords, array: true, null: false, default: []
      t.jsonb :metadata
      t.datetime :published_at
      t.virtual :search_vector, type: :tsvector, stored: true,
        as: "to_tsvector('english', coalesce(title, '') || ' ' || coalesce(body, ''))"
      t.timestamps
    end
    add_foreign_key :authors, :posts, column: :featured_post_id

    create_table :comments do |t|
      t.references :post, null: false, foreign_key: true
      t.references :author, null: false, foreign_key: true
      t.references :parent, foreign_key: {to_table: :comments}
      t.text :body, null: false
      t.timestamps
    end

    # Tag names are deliberately not unique: a legacy forum accumulates
    # duplicate tags, and the natural-key ambiguity examples need them.
    create_table :tags do |t|
      t.string :name, null: false
      t.string :slug, null: false
    end
    add_index :tags, :name

    create_table :post_tags do |t|
      t.references :post, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true
    end
    add_index :post_tags, [:post_id, :tag_id], unique: true

    create_table :bookmarks, id: false do |t|
      t.references :author, null: false, foreign_key: true
      t.references :post, null: false, foreign_key: true
    end
    add_index :bookmarks, [:author_id, :post_id], unique: true

    create_table :reactions do |t|
      t.references :author, null: false, foreign_key: true
      t.references :reactable, polymorphic: true, null: false
      t.string :kind, null: false, default: "like"
    end

    create_table :mentions do |t|
      t.references :comment, null: false, foreign_key: true
      t.string :mentioned_username, null: false
    end

    create_table :attachments, id: :uuid do |t|
      t.references :author, null: false, foreign_key: true
      t.string :filename, null: false
      t.string :content_type
      t.bigint :byte_size
      t.string :checksum
      t.timestamps
    end

    create_table :attachment_variants, id: :uuid do |t|
      t.references :attachment, type: :uuid, null: false, foreign_key: true
      t.string :variant, null: false
      t.bigint :byte_size
    end

    create_table :donations do |t|
      t.references :author, null: false, foreign_key: true
      t.references :post, foreign_key: true
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.string :currency, null: false, default: "USD"
      t.string :note
      t.timestamps
    end

    create_table :post_views, primary_key: [:post_id, :viewed_on] do |t|
      t.bigint :post_id, null: false
      t.date :viewed_on, null: false
      t.integer :count, null: false, default: 0
    end
    add_foreign_key :post_views, :posts
  end
end
