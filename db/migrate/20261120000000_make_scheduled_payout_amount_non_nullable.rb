# frozen_string_literal: true

class MakeScheduledPayoutAmountNonNullable < ActiveRecord::Migration[7.1]
  def change
    change_column_null :scheduled_payouts, :payout_amount_cents, false
  end
end
