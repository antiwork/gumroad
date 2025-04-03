# frozen_string_literal: true

class AddIpStateCountryToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :ip_country, :string
    add_column :purchases, :ip_state, :string
  end
end
