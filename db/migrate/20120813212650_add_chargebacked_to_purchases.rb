# frozen_string_literal: true

class AddChargebackedToPurchases < ActiveRecord::Migration
  def change
    add_column :purchases, :chargebacked, :boolean, default: false
  end
end
