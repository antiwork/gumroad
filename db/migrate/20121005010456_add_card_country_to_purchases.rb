# frozen_string_literal: true

class AddCardCountryToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :card_country, :string
  end
end
