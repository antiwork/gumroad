# frozen_string_literal: true

class CreateBalanceTransactions < ActiveRecord::Migration
  def change
    create_table :balance_transactions, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.timestamps

      t.references :user
      t.references :merchant_account
      t.references :balance

      t.references :purchase
      t.references :dispute
      t.references :refund
      t.references :credit

      t.datetime   :occurred_at

      t.string     :issued_amount_currency
      t.integer    :issued_amount_gross_cents
      t.integer    :issued_amount_net_cents

      t.string     :holding_amount_currency
      t.integer    :holding_amount_gross_cents
      t.integer    :holding_amount_net_cents
    end

    add_index :balance_transactions, :user_id
    add_index :balance_transactions, :merchant_account_id
    add_index :balance_transactions, :balance_id
    add_index :balance_transactions, :purchase_id
    add_index :balance_transactions, :dispute_id
    add_index :balance_transactions, :refund_id
    add_index :balance_transactions, :credit_id
  end
end
