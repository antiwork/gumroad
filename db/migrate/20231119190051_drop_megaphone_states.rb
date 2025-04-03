# frozen_string_literal: true

class DropMegaphoneStates < ActiveRecord::Migration[7.0]
  def up
    drop_table :megaphone_states
  end

  def down
    create_table "megaphone_states", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.integer "user_id"
      t.bigint "flags", default: 0, null: false
      t.datetime "created_at", precision: nil
      t.datetime "updated_at", precision: nil
      t.index ["user_id"], name: "index_megaphone_states_on_user_id", unique: true
    end
  end
end
