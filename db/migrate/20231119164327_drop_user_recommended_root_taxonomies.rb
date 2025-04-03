# frozen_string_literal: true

class DropUserRecommendedRootTaxonomies < ActiveRecord::Migration[7.0]
  def up
    drop_table :user_recommended_root_taxonomies
  end

  def down
    create_table "user_recommended_root_taxonomies", charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.bigint "user_id", null: false
      t.bigint "taxonomy_id", null: false
      t.integer "position", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["user_id", "position"], name: "index_user_recommended_root_taxonomies_on_user_id_and_position"
    end
  end
end
