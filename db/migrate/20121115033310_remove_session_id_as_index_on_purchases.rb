# frozen_string_literal: true

class RemoveSessionIdAsIndexOnPurchases < ActiveRecord::Migration
  def up
    remove_index :purchases, :session_id
  end

  def down
    add_index :purchases, :session_id
  end
end
