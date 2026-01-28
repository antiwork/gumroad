# frozen_string_literal: true

class ChangeDefaultMaxPurchaseCountOnLinks < ActiveRecord::Migration[4.2]
  def up
    change_column :links, :max_purchase_count, :integer, default: nil
  end

  def down
    change_column :links, :max_purchase_count, :integer, default: 999999
  end
end
