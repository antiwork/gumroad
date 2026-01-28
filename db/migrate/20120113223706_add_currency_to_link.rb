# frozen_string_literal: true

class AddCurrencyToLink < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :price_currency_type, :string, default: :usd
  end
end
