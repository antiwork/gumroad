# frozen_string_literal: true

class AddBaseTierPriceToPrices < ActiveRecord::Migration[5.1]
  # TODO(helen): remove this column when confident that tiered pricing data
  # migration was successful (see https://github.com/gumroad/web/pull/13830)
  def up
    add_column :prices, :base_tier_price, :boolean
  end

  def down
    remove_column :prices, :base_tier_price
  end
end
