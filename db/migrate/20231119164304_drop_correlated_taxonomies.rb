# frozen_string_literal: true

class DropCorrelatedTaxonomies < ActiveRecord::Migration[7.0]
  def up
    drop_table :correlated_taxonomies
  end

  def down
    create_table "correlated_taxonomies", charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.bigint "taxonomy_id", null: false
      t.json "related_taxonomy_ids", null: false
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
      t.index ["taxonomy_id"], name: "index_correlated_taxonomies_on_taxonomy_id", unique: true
    end
  end
end
