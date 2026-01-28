# frozen_string_literal: true

class AddCurrencyToPayments < ActiveRecord::Migration[4.2]
  def change
    add_column :payments, :currency, :string, default: "usd"
  end
end
