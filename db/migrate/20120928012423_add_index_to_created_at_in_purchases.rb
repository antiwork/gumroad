# frozen_string_literal: true

class AddIndexToCreatedAtInPurchases < ActiveRecord::Migration[4.2]
  def change
    add_index :purchases, :created_at
  end
end
