# frozen_string_literal: true

class AddPurchaseStateIndexToPurchases < ActiveRecord::Migration
  def change
    add_index :purchases, :purchase_state
  end
end
