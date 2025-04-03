# frozen_string_literal: true

class CreatePurchaseOfferCodeDiscounts < ActiveRecord::Migration[6.1]
  def change
    create_table :purchase_offer_code_discounts do |t|
      t.references :purchase, index: { unique: true }, null: false
      t.references :offer_code, null: false
      t.integer :offer_code_amount, null: false
      t.boolean :offer_code_is_percent, null: false, default: false
      t.integer :pre_discount_minimum_price_cents, null: false

      t.timestamps
    end
  end
end
