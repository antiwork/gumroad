# frozen_string_literal: true

class RemoveErrorCodeAsIndexOnPurchases < ActiveRecord::Migration
  def up
    remove_index :purchases, :error_code
  end

  def down
    add_index :purchases, :error_code
  end
end
