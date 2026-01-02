# frozen_string_literal: true

class AddRequiredProductToOfferCodes < ActiveRecord::Migration[7.1]
  def change
    add_reference :offer_codes, :required_product, foreign_key: { to_table: :links }
    add_column :offer_codes, :required_product_days_threshold, :integer
  end
end
