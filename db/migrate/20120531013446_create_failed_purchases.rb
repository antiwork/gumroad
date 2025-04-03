# frozen_string_literal: true

class CreateFailedPurchases < ActiveRecord::Migration
  def change
    create_table :failed_purchases do |t|
      # what to buy
      t.integer  :link_id
      t.integer  :price_cents
      # who tries to buy
      t.text     :email
      t.string   :ip_address
      # Card data
      t.string   :stripe_fingerprint
      t.string   :stripe_card_id
      t.string   :card_type
      t.boolean  :cvc_check
      t.string   :card_country

      t.timestamps
    end
  end
end
