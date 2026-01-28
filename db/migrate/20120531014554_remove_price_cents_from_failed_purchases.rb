# frozen_string_literal: true

class RemovePriceCentsFromFailedPurchases < ActiveRecord::Migration[4.2]
  def up
    remove_column :failed_purchases, :price_cents
  end

  def down
    add_column :failed_purchases, :price_cents, :string
  end
end
