# frozen_string_literal: true

class AddCustomizablePricesForVariants < ActiveRecord::Migration[5.1]
  def up
    add_column :base_variants, :customizable_price, :boolean
    add_column :prices, :suggested_price_cents, :integer
  end

  def down
    remove_column :prices, :suggested_price_cents
    remove_column :base_variants, :customizable_price
  end
end
