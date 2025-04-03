# frozen_string_literal: true

class AddBrowserGuidToEventsAndVisits < ActiveRecord::Migration
  def up
    add_column :events, :browser_guid, :string
    add_column :visits, :browser_guid, :string
  end

  def down
    remove_column :events, :browser_guid
    remove_column :visits, :browser_guid
  end
end
