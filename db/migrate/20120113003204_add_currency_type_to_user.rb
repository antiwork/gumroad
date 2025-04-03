# frozen_string_literal: true

class AddCurrencyTypeToUser < ActiveRecord::Migration
  def change
    add_column :users, :currency_type, :string, default: "usd"
  end
end
