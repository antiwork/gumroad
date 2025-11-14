# frozen_string_literal: true

class CreateBalanceLoads < ActiveRecord::Migration[7.1]
  def change
    create_table :balance_loads, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.bigint :user_id, null: false
      t.bigint :balance_load_credit_card_id, null: false
      t.bigint :refund_id
      t.integer :amount_cents, null: false
      t.string :currency, limit: 3, default: "usd", null: false
      t.string :state, limit: 20, default: "pending", null: false
      t.string :stripe_charge_id, limit: 191
      t.string :stripe_payment_intent_id, limit: 191
      t.integer :processor_fee_cents
      t.text :error_message
      t.text :metadata, size: :medium
      t.timestamps
    end

    add_index :balance_loads, :user_id
    add_index :balance_loads, :balance_load_credit_card_id, name: "index_balance_loads_on_bl_credit_card_id"
    add_index :balance_loads, :refund_id
    add_index :balance_loads, :state
    add_index :balance_loads, :stripe_payment_intent_id, name: "index_balance_loads_on_stripe_pi_id"
    add_index :balance_loads, :created_at
  end
end
