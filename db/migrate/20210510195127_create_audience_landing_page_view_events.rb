# frozen_string_literal: true

class CreateAudienceLandingPageViewEvents < ActiveRecord::Migration[6.1]
  def change
    # https://dev.mysql.com/doc/refman/5.6/en/integer-types.html
    starting_id = 2147483648 # INT maximum value signed + 1
    create_table "audience_landing_page_view_events", options: "ENGINE=InnoDB AUTO_INCREMENT=#{starting_id}" do |t|
      t.string "ip_address", limit: 255
      t.bigint "user_id"
      t.bigint "link_id"
      t.datetime "created_at"
      t.datetime "updated_at"
      t.string "referrer", limit: 255
      t.string "parent_referrer", limit: 255
      t.string "language", limit: 255
      t.string "browser", limit: 255
      t.boolean "is_mobile", default: false
      t.string "email", limit: 255
      t.integer "price_cents"
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
      t.bigint "visited_user_id"
      t.index ["browser_guid"], name: "index_browser_guid"
      t.index ["created_at"], name: "index_created_at"
      t.index ["link_id", "created_at"], name: "index_link_id_and_created_at"
      t.index ["ip_address"], name: "index_ip_address"
      t.index ["user_id"], name: "index_user_id"
      t.index ["visited_user_id", "created_at"], name: "index_visited_user_id_and_created_at"
    end
  end
end
