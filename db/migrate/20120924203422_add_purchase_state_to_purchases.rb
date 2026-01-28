# frozen_string_literal: true

class AddPurchaseStateToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :purchase_state, :string
  end
end
