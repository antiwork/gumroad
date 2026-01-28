# frozen_string_literal: true

class AddSellerIdIndexToPurchases < ActiveRecord::Migration[4.2]
  def change
    add_index :purchases, :seller_id
  end
end
