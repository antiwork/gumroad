# frozen_string_literal: true

class AddDiscountCodeToServiceCharge < ActiveRecord::Migration[4.2]
  def change
    add_column :service_charges, :discount_code, :string, limit: 100
  end
end
