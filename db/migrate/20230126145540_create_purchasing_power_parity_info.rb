# frozen_string_literal: true

class CreatePurchasingPowerParityInfo < ActiveRecord::Migration[7.0]
  def change
    create_table :purchasing_power_parity_infos do |t|
      t.references :purchase, null: false
      t.integer :factor

      t.timestamps
    end
  end
end
