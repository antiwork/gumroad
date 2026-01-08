# frozen_string_literal: true

class CreateRefundCoverageCharges < ActiveRecord::Migration[7.0]
  def change
    create_table :refund_coverage_charges do |t|
      t.integer :user_id, null: false
      t.integer :purchase_id, null: false
      t.integer :refund_id
      t.integer :credit_card_id
      t.integer :charge_cents, null: false
      t.string :charge_cents_currency, null: false, default: "usd"
      t.string :charge_processor_id, null: false
      t.string :processor_payment_intent_id
      t.string :charge_processor_transaction_id
      t.integer :charge_processor_fee_cents
      t.string :charge_processor_fee_cents_currency, null: false, default: "usd"
      t.timestamps
    end

    add_index :refund_coverage_charges, :user_id
    add_index :refund_coverage_charges, :purchase_id
    add_index :refund_coverage_charges, :refund_id
  end
end
