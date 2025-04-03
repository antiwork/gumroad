# frozen_string_literal: true

class AddShippingInfoToLinksAndPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :street_address, :string
    add_column :purchases, :city, :string
    add_column :purchases, :state, :string
    add_column :purchases, :zip_code, :string
    add_column :purchases, :country, :string

    add_column :links, :require_shipping, :boolean, default: false
  end
end
