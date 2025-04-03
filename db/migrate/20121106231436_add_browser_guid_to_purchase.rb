# frozen_string_literal: true

class AddBrowserGuidToPurchase < ActiveRecord::Migration
  def up
    add_column :purchases, :browser_guid, :string
    add_index :purchases, :browser_guid
  end

  def down
    remove_column :purchases, :browser_guid
    remove_index :purchases, :browser_guid
  end
end
