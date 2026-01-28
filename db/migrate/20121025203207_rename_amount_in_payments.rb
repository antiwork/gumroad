# frozen_string_literal: true

class RenameAmountInPayments < ActiveRecord::Migration[4.2]
  def up
    remove_column :payments, :amount
    add_column :payments, :amount_cents, :integer
  end
end
