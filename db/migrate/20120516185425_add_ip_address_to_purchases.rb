# frozen_string_literal: true

class AddIpAddressToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :ip_address, :string
  end
end
