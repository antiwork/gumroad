# frozen_string_literal: true

class AddPurchaseStateToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :purchase_state, :string
  end
end
