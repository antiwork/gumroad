# frozen_string_literal: true

class AddPurchaseNumberToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :purchase_number, :integer
  end
end
