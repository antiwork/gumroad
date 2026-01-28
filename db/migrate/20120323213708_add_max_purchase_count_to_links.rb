# frozen_string_literal: true

class AddMaxPurchaseCountToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :max_purchase_count, :integer, default: 999999
  end
end
