# frozen_string_literal: true

class CreateEvents < ActiveRecord::Migration
  def change
    create_table "events", force: true do |t|
      t.integer  "visit_id"
      t.string   "ip_address"
      t.string   "event_name"
      t.integer  "user_id"
      t.integer  "link_id"
      t.datetime "created_at"
      t.datetime "updated_at"
      t.string   "referrer"
      t.string   "parent_referrer"
      t.string   "language"
      t.string   "browser"
      t.boolean  "is_mobile",       default: false
      t.string   "email"
      t.integer  "purchase_id"
      t.integer  "price_cents"
      t.integer  "credit_card_id"
      t.string   "card_type"
      t.string   "card_visual"
      t.boolean  "purchase_state",  default: false
      t.string   "billing_zip"
      t.boolean  "chargeback",      default: false
      t.boolean  "refunded",        default: false
      t.string   "view_url"
      t.string   "fingerprint"
      t.string   "ip_country"
      t.float    "ip_longitude"
      t.float    "ip_latitude"
      t.boolean  "is_modal"
    end

    add_index "events", ["created_at"], name: "index_events_on_created_at"
    add_index "events", ["event_name"], name: "index_events_on_event_type"
    add_index "events", ["fingerprint"], name: "index_events_on_fingerprint"
    add_index "events", ["ip_address"], name: "index_events_on_ip_address"
    add_index "events", ["link_id"], name: "index_events_on_link_id"
    add_index "events", ["purchase_id"], name: "index_events_on_purchase_id"
    add_index "events", ["visit_id"], name: "index_events_on_visit_id"
  end
end
