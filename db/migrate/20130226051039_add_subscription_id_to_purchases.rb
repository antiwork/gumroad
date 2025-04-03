# frozen_string_literal: true

class AddSubscriptionIdToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :subscription_id, :integer
  end
end
