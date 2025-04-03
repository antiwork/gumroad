# frozen_string_literal: true

class RemoveFailedPurchases < ActiveRecord::Migration[7.0]
  def up
    drop_table :failed_purchases
  end

  def down
    create_table "failed_purchases", id: :integer, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.integer "link_id"
      t.text "email"
      t.string "ip_address"
      t.string "stripe_fingerprint"
      t.string "card_type"
      t.string "card_country"
      t.datetime "created_at", precision: nil
      t.datetime "updated_at", precision: nil
      t.index ["link_id"], name: "index_failed_purchases_on_link_id"
      t.index ["stripe_fingerprint"], name: "index_failed_purchases_on_stripe_fingerprint"
    end
  end
end
