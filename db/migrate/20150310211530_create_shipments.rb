# frozen_string_literal: true

class CreateShipments < ActiveRecord::Migration[4.2]
  def change
    create_table :shipments, options: "DEFAULT CHARACTER SET=utf8 COLLATE=utf8_unicode_ci" do |t|
      t.references :purchase
      t.string :ship_state
      t.datetime :shipped_at

      t.timestamps
    end
    add_index :shipments, :purchase_id
  end
end
