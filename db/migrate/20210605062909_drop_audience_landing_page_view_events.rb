# frozen_string_literal: true

class DropAudienceLandingPageViewEvents < ActiveRecord::Migration[6.1]
  def up
    drop_table :audience_landing_page_view_events
  end

  def down
    create_table "audience_landing_page_view_events", charset: "utf8mb4", collation: "utf8mb4_unicode_ci", force: :cascade do |t|
      t.string "ip_address"
      t.bigint "user_id"
      t.bigint "link_id"
      t.datetime "created_at"
      t.datetime "updated_at"
      t.string "referrer"
      t.string "parent_referrer"
      t.string "language"
      t.string "browser"
      t.boolean "is_mobile", default: false
      t.string "email"
      t.integer "price_cents"
      t.string "view_url"
      t.string "fingerprint"
      t.string "ip_country"
      t.float "ip_longitude"
      t.float "ip_latitude"
      t.boolean "is_modal"
      t.string "browser_fingerprint"
      t.string "browser_plugins"
      t.string "browser_guid"
      t.string "referrer_domain"
      t.string "ip_state"
      t.bigint "visited_user_id"
      t.index ["browser_guid"], name: "index_browser_guid"
      t.index ["created_at"], name: "index_created_at"
      t.index ["ip_address"], name: "index_ip_address"
      t.index ["link_id", "created_at"], name: "index_link_id_and_created_at"
      t.index ["user_id"], name: "index_user_id"
      t.index ["visited_user_id", "created_at"], name: "index_visited_user_id_and_created_at"
    end
  end
end
