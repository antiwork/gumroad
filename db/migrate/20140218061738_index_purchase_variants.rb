# frozen_string_literal: true

class IndexPurchaseVariants < ActiveRecord::Migration[4.2]
  def change
    add_index :purchases_variants, :purchase_id
    add_index :purchases_variants, :variant_id
  end
end
