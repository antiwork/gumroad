# frozen_string_literal: true

class AddPurchaseIdIndexToPurchaseSalesTaxInfos < ActiveRecord::Migration
  def change
    add_index :purchase_sales_tax_infos, :purchase_id
  end
end
