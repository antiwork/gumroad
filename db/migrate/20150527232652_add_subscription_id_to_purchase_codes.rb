# frozen_string_literal: true

class AddSubscriptionIdToPurchaseCodes < ActiveRecord::Migration
  def change
    add_column :purchase_codes, :subscription_id, :integer
    add_index :purchase_codes, :subscription_id
  end
end
