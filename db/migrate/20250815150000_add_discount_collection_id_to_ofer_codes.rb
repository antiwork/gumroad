class AddDiscountCollectionIdToOferCodes < ActiveRecord::Migration[7.1]
  def change
    add_reference :offer_codes, :discount_collection, null: true, foreign_key: true
  end
end
