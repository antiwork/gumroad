# frozen_string_literal: true

class AddPayoutEstimateIndexToBalances < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :balances,
              [:state, :merchant_account_id, :date, :user_id],
              name: "index_balances_on_state_merchant_account_date_for_payouts"
  end
end
