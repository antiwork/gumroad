# frozen_string_literal: true

class AddMaxPurchaseCountToLinks < ActiveRecord::Migration
  def change
    add_column :links, :max_purchase_count, :integer, default: 999999
  end
end
