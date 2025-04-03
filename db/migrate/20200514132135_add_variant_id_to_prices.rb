# frozen_string_literal: true

class AddVariantIdToPrices < ActiveRecord::Migration[5.1]
  def up
    add_reference :prices, :variant, index: true, type: :integer
  end

  def down
    remove_reference :prices, :variant
  end
end
