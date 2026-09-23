# frozen_string_literal: true

class CreateOfferCodesVariants < ActiveRecord::Migration[7.1]
  def change
    create_table :offer_codes_variants do |t|
      t.bigint :offer_code_id, null: false
      t.bigint :variant_id, null: false

      t.timestamps

      t.index [:offer_code_id, :variant_id], unique: true, name: "index_offer_codes_variants_on_code_and_variant"
      t.index :variant_id
    end
  end
end
