# frozen_string_literal: true

class PurchaseChangeCreateAtType < ActiveRecord::Migration[4.2]
  def change
    change_column(:purchases, :created_at, :datetime)
  end
end
