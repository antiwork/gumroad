# frozen_string_literal: true

class AddProcessorFeeCentsCurrencyToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_column :purchases, :processor_fee_cents_currency, :string, default: "usd"
  end
end
