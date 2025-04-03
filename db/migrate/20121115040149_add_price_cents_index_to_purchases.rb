# frozen_string_literal: true

class AddPriceCentsIndexToPurchases < ActiveRecord::Migration
  def up
    add_index "purchases", ["price_cents"]
  end

  def down
    remove_index "purchases", ["price_cents"]
  end
end
