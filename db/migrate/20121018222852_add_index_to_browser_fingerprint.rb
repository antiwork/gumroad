# frozen_string_literal: true

class AddIndexToBrowserFingerprint < ActiveRecord::Migration
  def change
    add_index :events, :browser_guid
    add_index :visits, :browser_guid
    add_index :events, :browser_fingerprint
    add_index :visits, :browser_fingerprint
  end
end
