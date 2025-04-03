# frozen_string_literal: true

class CreateSellerProfile < ActiveRecord::Migration[7.0]
  def change
    create_table :seller_profiles do |t|
      t.references :seller, index: true, null: false
      t.string :highlight_color
      t.string :background_color
      t.string :font
      t.timestamps
    end
  end
end
