# frozen_string_literal: true

class AddAmountPercentageColumnToOfferCodes < ActiveRecord::Migration
  def change
    add_column :offer_codes, :amount_percentage, :integer
  end
end
