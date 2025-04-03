# frozen_string_literal: true

class AddRatePurchase < ActiveRecord::Migration
  def up
    add_column :purchases, :rate_converted_to_usd, :string
  end

  def down
    remove_column :purchases, :rate_converted_to_usd
  end
end
