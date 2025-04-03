# frozen_string_literal: true

class CreateAffiliatePartialRefund < ActiveRecord::Migration
  def change
    create_table :affiliate_partial_refunds do |t|
      t.integer :amount_cents, default: 0
      t.integer :purchase_id, null: false
      t.integer :total_credit_cents, default: 0
      t.integer :affiliate_user_id
      t.integer :seller_id
      t.integer :affiliate_id
      t.integer :balance_id
      t.integer :affiliate_credit_id

      t.timestamps
    end

    add_index :affiliate_partial_refunds, :purchase_id
    add_index :affiliate_partial_refunds, :affiliate_user_id
    add_index :affiliate_partial_refunds, :seller_id
    add_index :affiliate_partial_refunds, :affiliate_id
    add_index :affiliate_partial_refunds, :balance_id
    add_index :affiliate_partial_refunds, :affiliate_credit_id
  end
end
