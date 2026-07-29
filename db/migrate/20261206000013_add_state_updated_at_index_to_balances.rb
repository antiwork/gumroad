# frozen_string_literal: true

class AddStateUpdatedAtIndexToBalances < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # MonitorGumroadHeldBalanceCurrencyJob runs daily and asks for the unpaid balances
    # touched since a fixed baseline whose holding_currency is not USD:
    #
    #   SELECT ... FROM balances
    #   WHERE state = 'unpaid' AND updated_at >= ?
    #     AND (holding_currency IS NULL OR CAST(holding_currency AS BINARY) <> 'usd')
    #     AND NOT (<merchant account shape>)
    #   ORDER BY id ASC LIMIT 500
    #
    # None of the three existing indexes on balances contains updated_at
    # ((state, merchant_account_id, date, user_id), (state, user_id, amount_cents) and
    # (user_id, merchant_account_id, date)), so the best plan available today uses the
    # state prefix alone and then re-checks the timestamp row by row. That set does not
    # stay small: a seller under the payout minimum keeps their unpaid balances
    # indefinitely, so "state = 'unpaid'" grows without bound. Worse, on a healthy day
    # this query matches nothing, and with ORDER BY id ASC MySQL is free to walk the
    # primary key hoping to fill the 500-row limit early -- never finding it, and so
    # reading the whole table.
    #
    # Leading with state and then updated_at makes the daily run a bounded range scan:
    # both predicates are served by the index, and the rows it visits are only those
    # touched since the baseline rather than every unpaid balance in the table. The
    # currency test cannot be indexed (it compares a CAST of the column, deliberately,
    # so that the check matches what the payout processors compare in Ruby) but it now
    # runs over that much smaller range.
    #
    # The existing indexes all stay: none is a prefix of this one, and they serve the
    # payout and per-seller lookups, which filter on merchant_account_id, date and
    # user_id rather than on updated_at.
    add_index :balances, [:state, :updated_at],
              name: "index_balances_on_state_and_updated_at"
  end
end
