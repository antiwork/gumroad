# frozen_string_literal: true

class CreateDisputeEvidences < ActiveRecord::Migration[7.0]
  def change
    create_table :dispute_evidences do |t|
      t.references :dispute, null: false, index: { unique: true }
      t.datetime :purchased_at
      t.string :customer_purchase_ip
      t.string :customer_email
      t.string :customer_name
      t.string :billing_address
      t.string :shipping_address
      t.string :shipped_at
      t.string :shipping_carrier
      t.string :shipping_tracking_number
      t.text :uncategorized_text
      t.datetime :submitted_at
      t.timestamps
    end
  end
end
