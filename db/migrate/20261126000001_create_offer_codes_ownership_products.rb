# frozen_string_literal: true

class CreateOfferCodesOwnershipProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :offer_codes_ownership_products do |t|
      t.references :offer_code, null: false
      t.references :product, null: false

      t.timestamps
    end
  end
end
