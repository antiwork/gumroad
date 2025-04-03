# frozen_string_literal: true

class CreateUpsellsProducts < ActiveRecord::Migration[7.0]
  def change
    create_table :upsells_products do |t|
      t.references :upsell, null: false
      t.references :product, null: false

      t.timestamps
    end
  end
end
