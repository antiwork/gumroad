# frozen_string_literal: true

class AddSellerIdIndexToPurchases < ActiveRecord::Migration
  def change
    add_index :purchases, :seller_id
  end
end
