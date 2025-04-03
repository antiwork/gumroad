# frozen_string_literal: true

class CreateSignupEvents < ActiveRecord::Migration[6.1]
  def change
    create_table :signup_events, options: "ENGINE=InnoDB DEFAULT CHARSET=latin1" do |t|
      t.integer "visit_id"
      t.string "ip_address", limit: 255
      t.integer "user_id"
      t.datetime "created_at"
      t.datetime "updated_at"
      t.string "referrer", limit: 255
      t.string "parent_referrer", limit: 255
      t.string "language", limit: 255
      t.string "browser", limit: 255
      t.boolean "is_mobile", default: false
      t.string "email", limit: 255
      t.string "view_url", limit: 255
      t.string "fingerprint", limit: 255
      t.string "ip_country", limit: 255
      t.float "ip_longitude"
      t.float "ip_latitude"
      t.boolean "is_modal"
      t.string "browser_fingerprint", limit: 255
      t.string "browser_plugins", limit: 255
      t.string "browser_guid", limit: 255
      t.string "referrer_domain", limit: 255
      t.string "ip_state", limit: 255
      t.string "active_test_path_assignments", limit: 255

      t.index ["browser_guid"], name: "index_events_on_browser_guid"
      t.index ["created_at"], name: "index_events_on_created_at"
      t.index ["ip_address"], name: "index_events_on_ip_address"
      t.index ["user_id"], name: "index_events_on_user_id"
      t.index ["visit_id"], name: "index_events_on_visit_id"

      # Columns derived from events table but not used
      t.string   "event_name"
      t.integer  "link_id"
      t.integer  "purchase_id"
      t.integer  "price_cents"
      t.integer  "credit_card_id"
      t.string   "card_type"
      t.string   "card_visual"
      t.boolean  "purchase_state",  default: false
      t.string   "billing_zip"
      t.boolean  "chargeback",      default: false
      t.boolean  "refunded"
    end
  end
end
