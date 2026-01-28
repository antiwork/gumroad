# frozen_string_literal: true

class RemoveStripeDisputedFromPurchases < ActiveRecord::Migration[4.2]
  def up
    remove_column :purchases, :stripe_disputed
  end

  def down
    add_column :purchases, :stripe_disputed, :boolean
  end
end
