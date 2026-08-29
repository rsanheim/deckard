class AddEdgeCaseColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :comments, :search_blob, :virtual,
      type: :tsvector, as: "to_tsvector('english', body)", stored: true

    create_enum :post_status, %w[draft published]
    add_column :posts, :status, :enum, enum_type: :post_status, default: "draft", null: false

    add_column :authors, :private_notes, :text
  end
end
