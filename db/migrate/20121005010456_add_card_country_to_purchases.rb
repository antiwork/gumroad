# frozen_string_literal: true

class AddCardCountryToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :card_country, :string
  end
end
