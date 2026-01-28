# frozen_string_literal: true

class AddPriceCentsIndexToPurchases < ActiveRecord::Migration[4.2]
  def up
    add_index "purchases", ["price_cents"]
  end

  def down
    remove_index "purchases", ["price_cents"]
  end
end
