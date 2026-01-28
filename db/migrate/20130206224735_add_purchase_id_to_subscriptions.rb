# frozen_string_literal: true

class AddPurchaseIdToSubscriptions < ActiveRecord::Migration[4.2]
  def change
    add_column :subscriptions, :purchase_id, :integer
  end
end
