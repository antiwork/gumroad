# frozen_string_literal: true

class AddPayoutPeriodEndDateToPayments < ActiveRecord::Migration[4.2]
  def change
    add_column :payments, :payout_period_end_date, :date
  end
end
