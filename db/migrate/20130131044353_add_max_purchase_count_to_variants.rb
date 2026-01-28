# frozen_string_literal: true

class AddMaxPurchaseCountToVariants < ActiveRecord::Migration[4.2]
  def change
    add_column :variants, :max_purchase_count, :integer
  end
end
