# frozen_string_literal: true

class CreateBlockedBrowserGuids < ActiveRecord::Migration
  def change
    create_table :blocked_browser_guids do |t|
      t.string :browser_guid
      t.datetime :blocked_at

      t.timestamps
    end
    add_index :blocked_browser_guids, :browser_guid
  end
end
