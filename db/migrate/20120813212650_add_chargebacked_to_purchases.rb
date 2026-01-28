# frozen_string_literal: true

class AddChargebackedToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :chargebacked, :boolean, default: false
  end
end
