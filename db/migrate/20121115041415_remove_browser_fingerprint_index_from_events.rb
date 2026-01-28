# frozen_string_literal: true

class RemoveBrowserFingerprintIndexFromEvents < ActiveRecord::Migration[4.2]
  def up
    remove_index "events", "browser_fingerprint"
  end

  def down
    add_index "events", "browser_fingerprint"
  end
end
