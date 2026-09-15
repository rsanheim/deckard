# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_14_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  # Custom types defined in this database.
  # Note that some types may not work with other database engines. Be careful if changing database.
  create_enum "post_status", ["draft", "published"]

  create_table "attachment_variants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "attachment_id", null: false
    t.bigint "byte_size"
    t.string "variant", null: false
    t.index ["attachment_id"], name: "index_attachment_variants_on_attachment_id"
  end

  create_table "attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "author_id", null: false
    t.bigint "byte_size"
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_attachments_on_author_id"
  end

  create_table "author_emails", force: :cascade do |t|
    t.string "address", null: false
    t.bigint "author_id", null: false
    t.string "label"
    t.datetime "verified_at"
    t.index ["author_id", "address"], name: "index_author_emails_on_author_id_and_address", unique: true
    t.index ["author_id"], name: "index_author_emails_on_author_id"
  end

  create_table "authors", force: :cascade do |t|
    t.uuid "api_token"
    t.binary "avatar"
    t.text "bio"
    t.date "birthday"
    t.datetime "created_at", null: false
    t.string "email"
    t.bigint "featured_post_id"
    t.datetime "joined_at"
    t.string "location"
    t.string "name", null: false
    t.text "private_notes"
    t.integer "role", default: 0, null: false
    t.jsonb "settings"
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.boolean "verified", default: false, null: false
    t.string "website"
    t.index ["username"], name: "index_authors_on_username", unique: true
  end

  create_table "bookmarks", id: false, force: :cascade do |t|
    t.bigint "author_id", null: false
    t.bigint "post_id", null: false
    t.index ["author_id", "post_id"], name: "index_bookmarks_on_author_id_and_post_id", unique: true
    t.index ["author_id"], name: "index_bookmarks_on_author_id"
    t.index ["post_id"], name: "index_bookmarks_on_post_id"
  end

  create_table "categories", force: :cascade do |t|
    t.text "description"
    t.text "moderator_notes"
    t.string "name", null: false
    t.string "slug", null: false
    t.string "type"
    t.index ["slug"], name: "index_categories_on_slug", unique: true
  end

  create_table "comments", force: :cascade do |t|
    t.bigint "author_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.bigint "parent_id"
    t.bigint "post_id", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_comments_on_author_id"
    t.index ["parent_id"], name: "index_comments_on_parent_id"
    t.index ["post_id"], name: "index_comments_on_post_id"
  end

  create_table "donations", force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.bigint "author_id", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "USD", null: false
    t.string "note"
    t.bigint "post_id"
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_donations_on_author_id"
    t.index ["post_id"], name: "index_donations_on_post_id"
  end

  create_table "mentions", force: :cascade do |t|
    t.bigint "comment_id", null: false
    t.string "mentioned_username", null: false
    t.index ["comment_id"], name: "index_mentions_on_comment_id"
  end

  create_table "post_tags", force: :cascade do |t|
    t.bigint "post_id", null: false
    t.bigint "tag_id", null: false
    t.index ["post_id", "tag_id"], name: "index_post_tags_on_post_id_and_tag_id", unique: true
    t.index ["post_id"], name: "index_post_tags_on_post_id"
    t.index ["tag_id"], name: "index_post_tags_on_tag_id"
  end

  create_table "post_views", primary_key: ["post_id", "viewed_on"], force: :cascade do |t|
    t.integer "count", default: 0, null: false
    t.bigint "post_id", null: false
    t.date "viewed_on", null: false
  end

  create_table "posts", force: :cascade do |t|
    t.bigint "author_id", null: false
    t.text "body"
    t.bigint "category_id"
    t.datetime "created_at", null: false
    t.string "keywords", default: [], null: false, array: true
    t.string "language"
    t.jsonb "metadata"
    t.datetime "published_at"
    t.virtual "search_vector", type: :tsvector, as: "to_tsvector('english'::regconfig, (((COALESCE(title, ''::character varying))::text || ' '::text) || COALESCE(body, ''::text)))", stored: true
    t.boolean "sensitive", default: false, null: false
    t.enum "status", default: "draft", null: false, enum_type: "post_status"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "visibility", default: "public", null: false
    t.index ["author_id"], name: "index_posts_on_author_id"
    t.index ["category_id"], name: "index_posts_on_category_id"
  end

  create_table "profiles", force: :cascade do |t|
    t.bigint "author_id", null: false
    t.text "bio"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_profiles_on_author_id", unique: true
  end

  create_table "reactions", force: :cascade do |t|
    t.bigint "author_id", null: false
    t.string "kind", default: "like", null: false
    t.bigint "reactable_id", null: false
    t.string "reactable_type", null: false
    t.index ["author_id"], name: "index_reactions_on_author_id"
    t.index ["reactable_type", "reactable_id"], name: "index_reactions_on_reactable"
  end

  create_table "tags", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.index ["name"], name: "index_tags_on_name"
  end

  add_foreign_key "attachment_variants", "attachments"
  add_foreign_key "attachments", "authors"
  add_foreign_key "author_emails", "authors"
  add_foreign_key "authors", "posts", column: "featured_post_id"
  add_foreign_key "bookmarks", "authors"
  add_foreign_key "bookmarks", "posts"
  add_foreign_key "comments", "authors"
  add_foreign_key "comments", "comments", column: "parent_id"
  add_foreign_key "comments", "posts"
  add_foreign_key "donations", "authors"
  add_foreign_key "donations", "posts"
  add_foreign_key "mentions", "comments"
  add_foreign_key "post_tags", "posts"
  add_foreign_key "post_tags", "tags"
  add_foreign_key "post_views", "posts"
  add_foreign_key "posts", "authors"
  add_foreign_key "posts", "categories"
  add_foreign_key "profiles", "authors"
  add_foreign_key "reactions", "authors"
end
