# frozen_string_literal: true

class AddPriceChangeAttributesToVariants < ActiveRecord::Migration[7.0]
  def change
    change_table :base_variants, bulk: true do |t|
      t.date :subscription_price_change_effective_date
      t.text :subscription_price_change_message, size: :long
    end
  end
end
