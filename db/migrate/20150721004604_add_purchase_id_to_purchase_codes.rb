# frozen_string_literal: true

class AddPurchaseIdToPurchaseCodes < ActiveRecord::Migration
  def change
    add_column :purchase_codes, :purchase_id, :integer
    add_index :purchase_codes, :purchase_id
  end
end
