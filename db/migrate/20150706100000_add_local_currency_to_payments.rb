# frozen_string_literal: true

class AddLocalCurrencyToPayments < ActiveRecord::Migration
  def change
    add_column :payments, :local_currency, :string
  end
end
