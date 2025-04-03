# frozen_string_literal: true

class RemoveLinkViewEvents < ActiveRecord::Migration[7.0]
  def up
    drop_table :link_view_events
  end

  def down
    create_table "link_view_events", charset: "latin1" do |t|
      t.integer "visit_id"
      t.string "ip_address"
      t.string "event_name"
      t.integer "user_id"
      t.integer "link_id"
      t.datetime "created_at", precision: nil
      t.datetime "updated_at", precision: nil
      t.string "referrer"
      t.string "parent_referrer"
      t.string "language"
      t.string "browser"
      t.boolean "is_mobile", default: false
      t.string "email"
      t.integer "purchase_id"
      t.integer "price_cents"
      t.integer "credit_card_id"
      t.string "card_type"
      t.string "card_visual"
      t.string "purchase_state"
      t.string "billing_zip"
      t.boolean "chargeback", default: false
      t.boolean "refunded", default: false
      t.string "view_url"
      t.string "fingerprint"
      t.string "ip_country"
      t.float "ip_longitude"
      t.float "ip_latitude"
      t.boolean "is_modal"
      t.text "friend_actions"
      t.string "browser_fingerprint"
      t.string "browser_plugins"
      t.string "browser_guid"
      t.string "referrer_domain"
      t.string "ip_state"
      t.string "active_test_path_assignments"
      t.integer "service_charge_id"
      t.index ["browser_guid"], name: "index_events_on_browser_guid"
      t.index ["created_at"], name: "index_events_on_created_at"
      t.index ["event_name", "link_id", "created_at"], name: "index_events_on_event_name_and_link_id"
      t.index ["ip_address"], name: "index_events_on_ip_address"
      t.index ["link_id"], name: "index_events_on_link_id"
      t.index ["purchase_id"], name: "index_events_on_purchase_id"
      t.index ["service_charge_id"], name: "index_events_on_service_charge_id"
      t.index ["user_id"], name: "index_events_on_user_id"
      t.index ["visit_id"], name: "index_events_on_visit_id"
    end
  end
end
