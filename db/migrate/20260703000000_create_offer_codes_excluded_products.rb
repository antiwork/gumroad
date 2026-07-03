# frozen_string_literal: true

class CreateOfferCodesExcludedProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :offer_codes_excluded_products do |t|
      t.bigint :offer_code_id, null: false
      t.bigint :product_id, null: false

      t.timestamps

      t.index [:offer_code_id, :product_id], unique: true, name: "index_offer_codes_excluded_products_on_code_and_product"
      t.index :product_id
    end
  end
end
