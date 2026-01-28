# frozen_string_literal: true

class AddIndexToSubscriptionIdInPurchases < ActiveRecord::Migration[4.2]
  def change
    add_index :purchases, :subscription_id
  end
end
