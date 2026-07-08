# frozen_string_literal: true

class AddCoveringIndexForHoldingBalanceToBalances < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # The weekly payout batch first has to answer "which users hold a positive
    # unpaid balance?" — a GROUP BY over the balances table filtered on
    # state = 'unpaid', grouped by user_id, summing amount_cents
    # (Payouts.holding_balance_user_ids / User.holding_balance).
    #
    # This index covers that query exactly: MySQL can read `state = 'unpaid'`
    # entries already ordered by user_id and sum amount_cents straight out of the
    # index, with no table lookups and no temporary table. Production profiling on
    # gumroad-private#870 measured the aggregation at ~3s on the existing
    # (state, merchant_account_id, date, user_id) index; this takes it to
    # sub-second and keeps it fast as the table grows.
    add_index :balances,
              [:state, :user_id, :amount_cents],
              name: "index_balances_on_state_user_id_amount_cents"
  end
end
