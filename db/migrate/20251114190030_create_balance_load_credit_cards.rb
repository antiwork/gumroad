# frozen_string_literal: true

class CreateBalanceLoadCreditCards < ActiveRecord::Migration[7.1]
  def change
    create_table :balance_load_credit_cards, charset: "utf8mb4", collation: "utf8mb4_unicode_ci" do |t|
      t.bigint :user_id, null: false
      t.string :stripe_customer_id, limit: 191, null: false
      t.string :processor_payment_method_id, limit: 191
      t.string :stripe_fingerprint, limit: 191, null: false
      t.string :visual, limit: 191, null: false
      t.string :card_type, limit: 191, null: false
      t.integer :expiry_month, null: false
      t.integer :expiry_year, null: false
      t.string :card_country, limit: 2
      t.boolean :is_default, default: true, null: false
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :balance_load_credit_cards, :user_id
    add_index :balance_load_credit_cards, [:user_id, :is_default]
    add_index :balance_load_credit_cards, :stripe_fingerprint
    add_index :balance_load_credit_cards, :deleted_at
  end
end
