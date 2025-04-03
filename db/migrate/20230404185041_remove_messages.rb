# frozen_string_literal: true

class RemoveMessages < ActiveRecord::Migration[7.0]
  def up
    drop_table :messages
  end

  def down
    create_table "messages", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.integer "parent_id"
      t.integer "purchase_id"
      t.integer "flags", default: 0, null: false
      t.string "state", limit: 191
      t.text "text"
      t.string "title", limit: 191
      t.datetime "read_at", precision: nil
      t.datetime "responded_at", precision: nil
      t.datetime "deleted_at", precision: nil
      t.datetime "created_at", precision: nil
      t.datetime "updated_at", precision: nil
      t.index ["parent_id"], name: "index_messages_on_parent_id"
      t.index ["purchase_id"], name: "index_messages_on_purchase_id"
    end
  end
end
