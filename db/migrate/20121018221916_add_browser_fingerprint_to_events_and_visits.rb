# frozen_string_literal: true

class AddBrowserFingerprintToEventsAndVisits < ActiveRecord::Migration
  def up
    add_column :events, :browser_fingerprint, :string
    add_column :visits, :browser_fingerprint, :string
  end

  def down
    remove_column :events, :browser_fingerprint
    remove_column :visits, :browser_fingerprint
  end
end
