class AddRequiredProductFieldsToOfferCodes < ActiveRecord::Migration[7.1]
  def change
    add_column :offer_codes, :required_product_id, :integer
    add_index :offer_codes, :required_product_id
    add_column :offer_codes, :required_product_ownership_months, :integer
    add_column :offer_codes, :fallback_discount_percentage, :integer
    add_column :offer_codes, :fallback_discount_cents, :integer
  end
end
