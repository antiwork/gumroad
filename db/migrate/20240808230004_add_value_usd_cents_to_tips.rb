# frozen_string_literal: true

class AddValueUsdCentsToTips < ActiveRecord::Migration[7.1]
  def change
    add_column :tips, :value_usd_cents, :integer, null: false, default: 0
  end
end
