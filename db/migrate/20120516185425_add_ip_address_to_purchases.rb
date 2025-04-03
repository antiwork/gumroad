# frozen_string_literal: true

class AddIpAddressToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :ip_address, :string
  end
end
