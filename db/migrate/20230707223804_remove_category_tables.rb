# frozen_string_literal: true

class RemoveCategoryTables < ActiveRecord::Migration[7.0]
  def up
    drop_table :categories
    drop_table :product_categorizations
    drop_table :user_categorizations
  end

  def down
    create_table "categories", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.string "name", limit: 100
      t.datetime "created_at", precision: nil
      t.datetime "updated_at", precision: nil
      t.index ["name"], name: "index_categories_on_name"
    end

    create_table "product_categorizations", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.integer "category_id"
      t.integer "product_id"
      t.datetime "created_at", precision: nil
      t.datetime "updated_at", precision: nil
      t.index ["category_id"], name: "index_product_categorizations_on_category_id"
      t.index ["product_id"], name: "index_product_categorizations_on_product_id"
    end

    create_table "user_categorizations", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.integer "category_id"
      t.integer "user_id"
      t.datetime "created_at", precision: nil
      t.datetime "updated_at", precision: nil
      t.index ["category_id"], name: "index_user_categorizations_on_category_id"
      t.index ["user_id"], name: "index_user_categorizations_on_user_id"
    end
  end
end
