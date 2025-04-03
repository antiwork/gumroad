# frozen_string_literal: true

class DropBlockedIp < ActiveRecord::Migration[6.1]
  def up
    drop_table :blocked_ips
  end

  def down
    create_table "blocked_ips", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
      t.string "ip_address"
      t.datetime "created_at"
      t.datetime "updated_at"
      t.boolean "banned"
      t.datetime "banned_at"
    end
  end
end
