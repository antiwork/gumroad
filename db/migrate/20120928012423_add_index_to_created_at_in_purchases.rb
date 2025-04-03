# frozen_string_literal: true

class AddIndexToCreatedAtInPurchases < ActiveRecord::Migration
  def change
    add_index :purchases, :created_at
  end
end
