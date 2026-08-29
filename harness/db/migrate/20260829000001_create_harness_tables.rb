class CreateHarnessTables < ActiveRecord::Migration[8.1]
  def change
    create_table :authors do |t|
      t.string :name, null: false
      t.string :email
      t.timestamps
    end

    create_table :profiles do |t|
      t.references :author, null: false, foreign_key: true
      t.text :bio
      t.timestamps
    end

    create_table :posts do |t|
      t.references :author, null: false, foreign_key: true
      t.string :title, null: false
      t.text :body
      t.timestamps
    end

    create_table :comments do |t|
      t.references :post, null: false, foreign_key: true
      t.references :author, null: false, foreign_key: true
      t.text :body, null: false
      t.timestamps
    end
  end
end
