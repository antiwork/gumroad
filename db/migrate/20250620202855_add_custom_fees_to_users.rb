# frozen_string_literal: true

class AddCustomFeesToUsers < ActiveRecord::Migration[7.1]
  def change
    change_table :users, bulk: true do |t|
      t.decimal :custom_direct_fee_percentage, precision: 5, scale: 2
      t.remove :custom_discover_fee_percentage if column_exists?(:users, :custom_discover_fee_percentage)
    end
  end
end
