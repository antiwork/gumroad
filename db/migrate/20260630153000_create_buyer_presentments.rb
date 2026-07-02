# frozen_string_literal: true

class CreateBuyerPresentments < ActiveRecord::Migration[7.1]
  def change
    create_table :charge_presentments do |t|
      t.bigint :charge_id, null: false
      t.string :processor, null: false
      t.string :presentment_currency, null: false
      t.bigint :presentment_total_cents, null: false
      t.bigint :presentment_gumroad_amount_cents, null: false
      # Quote columns stay nullable at the database level: local payment methods where the
      # quote cannot lock and Phase 3 PayPal create presentment rows without them. Presence
      # for quote-backed Stripe rows is enforced by application validation.
      t.string :stripe_fx_quote_id
      t.datetime :stripe_fx_quote_expires_at
      t.decimal :fx_rate, precision: 30, scale: 15

      t.timestamps
    end

    change_table :charge_presentments, bulk: true do |t|
      t.index :charge_id, unique: true
      t.index :stripe_fx_quote_id
    end

    create_table :purchase_presentments do |t|
      t.bigint :purchase_id, null: false
      t.bigint :charge_presentment_id
      t.string :processor, null: false
      t.string :presentment_currency, null: false
      t.bigint :presentment_price_cents, null: false
      t.bigint :presentment_tip_cents, null: false, default: 0
      t.bigint :presentment_seller_tax_cents, null: false, default: 0
      t.bigint :presentment_gumroad_tax_cents, null: false, default: 0
      t.bigint :presentment_shipping_cents, null: false, default: 0
      t.bigint :presentment_total_cents, null: false
      t.bigint :presentment_gumroad_amount_cents, null: false

      t.timestamps
    end

    change_table :purchase_presentments, bulk: true do |t|
      t.index :purchase_id, unique: true
      t.index :charge_presentment_id
    end
  end
end
