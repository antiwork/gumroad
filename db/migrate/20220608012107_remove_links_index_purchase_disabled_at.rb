# frozen_string_literal: true

class RemoveLinksIndexPurchaseDisabledAt < ActiveRecord::Migration[4.2]
  def up
    remove_index :links, :purchase_disabled_at
  end

  def down
    add_index :links, :purchase_disabled_at
  end
end
