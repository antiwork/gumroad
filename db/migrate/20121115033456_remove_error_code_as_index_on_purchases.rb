# frozen_string_literal: true

class RemoveErrorCodeAsIndexOnPurchases < ActiveRecord::Migration[4.2]
  def up
    remove_index :purchases, :error_code
  end

  def down
    add_index :purchases, :error_code
  end
end
