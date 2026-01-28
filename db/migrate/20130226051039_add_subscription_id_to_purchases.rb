# frozen_string_literal: true

class AddSubscriptionIdToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :subscription_id, :integer
  end
end
