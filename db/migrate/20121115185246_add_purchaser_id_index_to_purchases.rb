# frozen_string_literal: true

class AddPurchaserIdIndexToPurchases < ActiveRecord::Migration
  def up
    add_index "purchases", "purchaser_id"
  end

  def down
    remove_index "purchases", "purchaser_id"
  end
end
