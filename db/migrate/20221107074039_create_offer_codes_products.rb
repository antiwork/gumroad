# frozen_string_literal: true

class CreateOfferCodesProducts < ActiveRecord::Migration[4.2]
  def change
    create_table :offer_codes_products do |t|
      t.references :offer_code
      t.references :product

      t.timestamps
    end
  end
end
