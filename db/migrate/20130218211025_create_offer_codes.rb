# frozen_string_literal: true

class CreateOfferCodes < ActiveRecord::Migration
  def change
    create_table :offer_codes do |t|
      t.references :link
      t.string :name
      t.integer :amount_cents
      t.integer :max_purchase_count
      t.datetime :deleted_at

      t.timestamps
    end
  end
end
