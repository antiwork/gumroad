# frozen_string_literal: true

class AddDiscoverFeeToLinks < ActiveRecord::Migration[6.1]
  def change
    add_column :links, :discover_fee_per_thousand, :integer, default: 100
  end
end
