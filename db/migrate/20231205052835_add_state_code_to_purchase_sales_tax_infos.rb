# frozen_string_literal: true

class AddStateCodeToPurchaseSalesTaxInfos < ActiveRecord::Migration[4.2]
  def change
    add_column :purchase_sales_tax_infos, :state_code, :string
  end
end
