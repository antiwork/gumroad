# frozen_string_literal: true

class RemoveBrowserFingerprintIndexFromEvents < ActiveRecord::Migration
  def up
    remove_index "events", "browser_fingerprint"
  end

  def down
    add_index "events", "browser_fingerprint"
  end
end
