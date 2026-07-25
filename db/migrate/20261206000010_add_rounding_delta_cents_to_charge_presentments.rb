# frozen_string_literal: true

class AddRoundingDeltaCentsToChargePresentments < ActiveRecord::Migration[7.1]
  def change
    # Signed: positive when smart rounding raised the buyer's total above the exact
    # converted amount, negative when it lowered it. The whole difference sits on
    # Gumroad's side of the charge — seller proceeds, tax, shipping, balances and payouts
    # are all booked from canonical USD and are identical either way — so this column is
    # what makes the difference auditable and monitorable alongside foreign-exchange drift.
    add_column :charge_presentments, :rounding_delta_cents, :bigint, default: 0, null: false
  end
end
