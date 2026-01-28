# frozen_string_literal: true

class AddPurchasesSellerStateDateIndex < ActiveRecord::Migration[4.2]
  def change
    add_index :purchases, [:seller_id, :purchase_state, :created_at]
  end
end
