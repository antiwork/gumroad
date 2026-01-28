# frozen_string_literal: true

class RemoveNullConstraintFromSelectedProductIdUpsellPurchases < ActiveRecord::Migration[4.2]
  def change
    change_column_null :upsell_purchases, :selected_product_id, true
  end
end
