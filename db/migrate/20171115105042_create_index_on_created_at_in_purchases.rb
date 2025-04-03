# frozen_string_literal: true

class CreateIndexOnCreatedAtInPurchases < ActiveRecord::Migration
  def change
    add_index :purchases, :created_at
  end
end
