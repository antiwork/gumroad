# frozen_string_literal: true

class AddPurchaseStateIndexToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_index :purchases, :purchase_state
  end
end
