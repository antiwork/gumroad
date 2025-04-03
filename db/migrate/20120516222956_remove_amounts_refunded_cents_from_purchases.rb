# frozen_string_literal: true

class RemoveAmountsRefundedCentsFromPurchases < ActiveRecord::Migration
  def up
    remove_column :purchases, :amount_refunded_cents
  end

  def down
    add_column :purchases, :amount_refunded_cents, :integer
  end
end
