# frozen_string_literal: true

class AddCurrencyTypeToUser < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :currency_type, :string, default: "usd"
  end
end
