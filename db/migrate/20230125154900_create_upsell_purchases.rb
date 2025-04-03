# frozen_string_literal: true

class CreateUpsellPurchases < ActiveRecord::Migration[7.0]
  def change
    create_table :upsell_purchases do |t|
      t.references :upsell, null: false
      t.references :purchase, null: false
      t.references :selected_product, null: false
      t.references :upsell_variant

      t.timestamps
    end
  end
end
