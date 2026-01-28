# frozen_string_literal: true

class AddAmountPercentageColumnToOfferCodes < ActiveRecord::Migration[4.2]
  def change
    add_column :offer_codes, :amount_percentage, :integer
  end
end
