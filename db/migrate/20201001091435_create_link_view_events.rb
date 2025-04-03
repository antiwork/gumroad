# frozen_string_literal: true

class CreateLinkViewEvents < ActiveRecord::Migration[6.0]
  def change
    # https://dev.mysql.com/doc/refman/5.6/en/integer-types.html
    starting_id = 2147483648 # INT maximum value signed + 1
    create_table "link_view_events", options: "ENGINE=InnoDB AUTO_INCREMENT=#{starting_id} DEFAULT CHARSET=latin1" do |t|
      t.integer "visit_id"
      t.string "ip_address", limit: 255
      t.string "event_name", limit: 255
      t.integer "user_id"
      t.integer "link_id"
      t.datetime "created_at"
      t.datetime "updated_at"
      t.string "referrer", limit: 255
      t.string "parent_referrer", limit: 255
      t.string "language", limit: 255
      t.string "browser", limit: 255
      t.boolean "is_mobile", default: false
      t.string "email", limit: 255
      t.integer "purchase_id"
      t.integer "price_cents"
      t.integer "credit_card_id"
      t.string "card_type", limit: 255
      t.string "card_visual", limit: 255
      t.string "purchase_state", limit: 255
      t.string "billing_zip", limit: 255
      t.boolean "chargeback", default: false
      t.boolean "refunded", default: false
      t.string "view_url", limit: 255
      t.string "fingerprint", limit: 255
      t.string "ip_country", limit: 255
      t.float "ip_longitude"
      t.float "ip_latitude"
      t.boolean "is_modal"
      t.text "friend_actions"
      t.string "browser_fingerprint", limit: 255
      t.string "browser_plugins", limit: 255
      t.string "browser_guid", limit: 255
      t.string "referrer_domain", limit: 255
      t.string "ip_state", limit: 255
      t.string "active_test_path_assignments", limit: 255
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
