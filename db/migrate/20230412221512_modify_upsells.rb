# frozen_string_literal: true

class ModifyUpsells < ActiveRecord::Migration[7.0]
  def change
    change_table(:upsells, bulk: true) do |t|
      t.rename :offered_product_id, :product_id
      t.rename :offered_variant_id, :variant_id

      t.boolean :universal, null: false, default: false
    end
  end
end
