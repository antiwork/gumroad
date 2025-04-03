# frozen_string_literal: true

class CreateChargePurchases < ActiveRecord::Migration[7.0]
  def change
    create_table :charge_purchases do |t|
      t.references :charge, null: false
      t.references :purchase, null: false

      t.timestamps
    end
  end
end
