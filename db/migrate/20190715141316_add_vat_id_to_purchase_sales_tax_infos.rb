# frozen_string_literal: true

class AddVatIdToPurchaseSalesTaxInfos < ActiveRecord::Migration[4.2]
  def change
    add_column :purchase_sales_tax_infos, :business_vat_id, :string, default: nil, null: true
  end
end
