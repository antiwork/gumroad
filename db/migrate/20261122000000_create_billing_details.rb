# frozen_string_literal: true

class CreateBillingDetails < ActiveRecord::Migration[7.1]
  def change
    create_table :billing_details do |t|
      t.bigint :purchaser_id, null: false
      t.string :full_name, null: false
      t.string :business_name
      t.string :business_id
      t.string :street_address, null: false
      t.string :city, null: false
      t.string :state
      t.string :zip_code, null: false
      t.string :country_code, limit: 2, null: false
      t.text :additional_notes
      t.boolean :auto_email_invoice_enabled, null: false, default: true

      t.timestamps

      t.index :purchaser_id, unique: true
    end
  end
end
