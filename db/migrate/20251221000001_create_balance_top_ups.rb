# frozen_string_literal: true

class CreateBalanceTopUps < ActiveRecord::Migration[7.1]
  def change
    create_table :balance_top_ups do |t|
      t.references :user, null: false, index: true
      t.references :credit_card, null: false, index: true
      t.references :purchase, index: true
      t.references :credit, index: true
      t.integer :amount_cents, null: false
      t.string :state, null: false, default: "pending"
      t.string :processor, null: false
      t.string :processor_transaction_id
      t.string :processor_payment_intent_id
      t.string :error_message
      t.timestamps
    end

    add_index :balance_top_ups, :processor_transaction_id, unique: true
  end
end
