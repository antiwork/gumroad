# frozen_string_literal: true

class RemoveUnusedIndexFromPurchases < ActiveRecord::Migration
  def up
    remove_index :purchases, :created_at
    remove_index :purchases, :price_cents
  end
end
