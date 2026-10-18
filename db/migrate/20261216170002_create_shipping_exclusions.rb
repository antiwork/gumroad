# frozen_string_literal: true

class CreateShippingExclusions < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_exclusions do |t|
      t.integer :link_id, null: false
      t.string :country_code, null: false
      t.timestamps

      t.index [:link_id, :country_code], unique: true
    end
  end
end
