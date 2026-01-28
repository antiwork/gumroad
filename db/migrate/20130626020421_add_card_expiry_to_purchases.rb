# frozen_string_literal: true

class AddCardExpiryToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :card_expiry_month, :integer
    add_column :purchases, :card_expiry_year, :integer
  end
end
