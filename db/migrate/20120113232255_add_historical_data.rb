# frozen_string_literal: true

class AddHistoricalData < ActiveRecord::Migration[4.2]
  def up
    Purchase.update_all(displayed_price_currency_type: "usd")
    Purchase.update_all("displayed_price_cents = price_cents")
  end

  def down
  end
end
