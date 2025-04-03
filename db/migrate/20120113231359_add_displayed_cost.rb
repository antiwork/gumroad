# frozen_string_literal: true

class AddDisplayedCost < ActiveRecord::Migration
  def change
    add_column :purchases, :displayed_price_cents, :integer
    add_column :purchases, :displayed_price_currency_type, :string, default: :usd
  end
end
