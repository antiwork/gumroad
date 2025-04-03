# frozen_string_literal: true

class MakePurchaseFindable < ActiveRecord::Migration
  def up
    add_index :purchases, :link_id
  end

  def down
    remove_index :purchases, :link_id
  end
end
