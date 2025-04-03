# frozen_string_literal: true

class AddIndexToSubscriptionIdInPurchases < ActiveRecord::Migration
  def change
    add_index :purchases, :subscription_id
  end
end
