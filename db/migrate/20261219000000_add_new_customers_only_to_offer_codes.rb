# frozen_string_literal: true

class AddNewCustomersOnlyToOfferCodes < ActiveRecord::Migration[7.1]
  def change
    add_column :offer_codes, :new_customers_only, :boolean, default: false, null: false
  end
end
