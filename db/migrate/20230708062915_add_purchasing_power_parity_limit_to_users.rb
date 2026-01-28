# frozen_string_literal: true

class AddPurchasingPowerParityLimitToUsers < ActiveRecord::Migration[4.2]
  def change
    change_table :users, bulk: true do |t|
      t.integer :purchasing_power_parity_limit
    end
  end
end
