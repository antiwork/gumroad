# frozen_string_literal: true

class DropProductEmbeddings < ActiveRecord::Migration[7.0]
  def up
    drop_table :product_embeddings
  end

  def down
    create_table "product_embeddings", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
      t.bigint "product_id", null: false
      t.text "body", size: :medium
      t.json "vector"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["product_id"], name: "index_product_embeddings_on_product_id", unique: true
    end
  end
end
