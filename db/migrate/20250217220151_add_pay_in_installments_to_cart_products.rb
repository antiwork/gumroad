# frozen_string_literal: true

class AddPayInInstallmentsToCartProducts < ActiveRecord::Migration[4.2]
  def change
    add_column :cart_products, :pay_in_installments, :boolean, null: false, default: false
  end
end
