# frozen_string_literal: true

class ChangePaymentAmountCentsToBigint < ActiveRecord::Migration[4.2]
  def up
    change_column :payments, :amount_cents, :bigint
  end

  def down
    change_column :payments, :amount_cents, :integer
  end
end
