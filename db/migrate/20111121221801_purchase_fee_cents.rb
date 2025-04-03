# frozen_string_literal: true

class PurchaseFeeCents < ActiveRecord::Migration
  def up
    add_column :purchases, :fee_cents, :integer
    Purchase.update_all({ fee_cents: 0 })
  end

  def down
    remove_column :purchase, :fee_cents, :integer
  end
end
