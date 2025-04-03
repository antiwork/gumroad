# frozen_string_literal: true

class PurchaseChangeCreateAtType < ActiveRecord::Migration
  def change
    change_column(:purchases, :created_at, :datetime)
  end
end
