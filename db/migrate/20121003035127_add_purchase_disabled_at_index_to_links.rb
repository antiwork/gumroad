# frozen_string_literal: true

class AddPurchaseDisabledAtIndexToLinks < ActiveRecord::Migration[4.2]
  def change
    add_index :links, :purchase_disabled_at
  end
end
