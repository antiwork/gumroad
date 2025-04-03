# frozen_string_literal: true

class CreateStaffPickedProducts < ActiveRecord::Migration[7.0]
  def change
    create_table :staff_picked_products do |t|
      t.references :product, index: { unique: true }, null: false
      t.datetime :deleted_at
      t.timestamps
    end
  end
end
