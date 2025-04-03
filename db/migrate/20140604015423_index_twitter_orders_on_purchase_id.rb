# frozen_string_literal: true

class IndexTwitterOrdersOnPurchaseId < ActiveRecord::Migration
  def change
    add_index :twitter_orders, :purchase_id
  end
end
