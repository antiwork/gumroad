# frozen_string_literal: true

class ModifyUpsellsSelectedProducts < ActiveRecord::Migration[4.2]
  def change
    change_table(:upsells_selected_products, bulk: true) do |t|
      t.rename :product_id, :selected_product_id
    end
  end
end
