# frozen_string_literal: true

class AddHistoricalData < ActiveRecord::Migration
  def up
    Purchase.update_all(displayed_price_currency_type: "usd")
    Purchase.update_all("displayed_price_cents = price_cents")
  end

  def down
  end
end
