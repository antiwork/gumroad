# frozen_string_literal: true

class CreateVisits < ActiveRecord::Migration
  def change
    create_table "visits", force: true do |t|
      t.string   "ip_address"
      t.datetime "created_at"
      t.string   "entry_point"
      t.datetime "updated_at"
      t.string   "fingerprint"
      t.integer  "user_id"
      t.boolean  "is_modal"
    end

    add_index "visits", ["created_at"], name: "index_visits_on_created_at"
    add_index "visits", ["entry_point"], name: "index_visits_on_entry_point"
    add_index "visits", ["fingerprint"], name: "index_visits_on_fingerprint"
    add_index "visits", ["ip_address"], name: "index_visits_on_ip_address"
  end
end
