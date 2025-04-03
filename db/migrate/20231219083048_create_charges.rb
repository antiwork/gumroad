# frozen_string_literal: true

class CreateCharges < ActiveRecord::Migration[7.0]
  def change
    create_table :charges do |t|
      t.references :order, null: false
      t.references :seller, null: false
      t.string :processor, null: false
      t.string :processor_transaction_id, index: { unique: true }
      t.string :payment_method_fingerprint
      t.references :credit_card
      t.references :merchant_account, null: false
      t.bigint :amount_cents
      t.bigint :gumroad_amount_cents
      t.bigint :processor_fee_cents
      t.string :processor_fee_currency
      t.string :paypal_order_id, index: { unique: true }
      t.string :stripe_payment_intent_id
      t.string :stripe_setup_intent_id

      t.timestamps
    end
  end
end
