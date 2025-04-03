# frozen_string_literal: true

class DropProcessedAudios < ActiveRecord::Migration[7.1]
  def up
    drop_table :processed_audios
  end

  def down
    create_table "processed_audios", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
      t.integer "product_file_id"
      t.string "url", limit: 1024
      t.datetime "created_at", precision: nil
      t.datetime "updated_at", precision: nil
      t.datetime "deleted_at", precision: nil
      t.index ["product_file_id"], name: "index_processed_audios_on_product_file_id"
    end
  end
end
