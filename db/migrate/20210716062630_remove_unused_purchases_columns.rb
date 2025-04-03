# frozen_string_literal: true

class RemoveUnusedPurchasesColumns < ActiveRecord::Migration[6.1]
  def up
    change_table :purchases, bulk: true do |t|
      # Added
      t.datetime :deleted_at
      t.index [:purchase_state, :created_at]

      # Changed
      t.change :id, :bigint, null: false, unique: true, auto_increment: true
      t.change :flags, :bigint, default: 0, null: false
      t.change :seller_id, :bigint
      t.change :link_id, :bigint
      t.change :credit_card_id, :bigint
      t.change :purchaser_id, :bigint
      t.change :purchase_success_balance_id, :bigint
      t.change :purchase_chargeback_balance_id, :bigint
      t.change :purchase_refund_balance_id, :bigint
      t.change :offer_code_id, :bigint
      t.change :subscription_id, :bigint
      t.change :preorder_id, :bigint
      t.change :zip_tax_rate_id, :bigint
      t.change :merchant_account_id, :bigint
      t.change :affiliate_id, :bigint
      t.change :price_id, :bigint

      # Removed
      t.remove :subunsub
      t.remove :purchase_number
      t.remove :in_progress
      t.remove :billing_name
      t.remove :billing_zip_code
      t.remove :follow_up_count
      t.remove :parent_id
      t.remove_index :processor_payment_intent_id
      t.remove_index :processor_setup_intent_id
      t.remove_index [:seller_id, :purchase_state, :flags, :email]
    end
  end

  def down
    change_table :purchases, bulk: true do |t|
      # Previously added
      t.remove :deleted_at
      t.remove_index [:purchase_state, :created_at]

      # Previously changed
      t.change :id, :integer, null: false, unique: true, auto_increment: true
      t.change :flags, :integer, default: 0, null: false
      t.change :seller_id, :integer
      t.change :link_id, :integer
      t.change :credit_card_id, :integer
      t.change :purchaser_id, :integer
      t.change :purchase_success_balance_id, :integer
      t.change :purchase_chargeback_balance_id, :integer
      t.change :purchase_refund_balance_id, :integer
      t.change :offer_code_id, :integer
      t.change :subscription_id, :integer
      t.change :preorder_id, :integer
      t.change :zip_tax_rate_id, :integer
      t.change :merchant_account_id, :integer
      t.change :affiliate_id, :integer
      t.change :price_id, :integer

      # Previously removed
      t.string :subunsub
      t.boolean :in_progress, default: false
      t.integer :purchase_number
      t.string :billing_name
      t.string :billing_zip_code
      t.integer :follow_up_count
      t.integer :parent_id
      t.index :processor_payment_intent_id
      t.index :processor_setup_intent_id
      t.index [:seller_id, :purchase_state, :flags, :email], name: :index_purchases_on_seller_id_and_state_and_flags_and_email, length: { email: 191 }
    end
  end
end
