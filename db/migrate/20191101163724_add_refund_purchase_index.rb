# frozen_string_literal: true

class AddRefundPurchaseIndex < ActiveRecord::Migration
  def up
    add_index :refunds, :purchase_id
  end

  def down
    remove_index :refunds, :purchase_id
  end
end
