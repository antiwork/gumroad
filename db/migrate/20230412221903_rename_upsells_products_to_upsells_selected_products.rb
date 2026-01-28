# frozen_string_literal: true

class RenameUpsellsProductsToUpsellsSelectedProducts < ActiveRecord::Migration[4.2]
  def change
    rename_table :upsells_products, :upsells_selected_products
  end
end
