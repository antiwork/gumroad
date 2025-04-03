# frozen_string_literal: true

class AddPurchaseIdToSubscriptions < ActiveRecord::Migration
  def change
    add_column :subscriptions, :purchase_id, :integer
  end
end
