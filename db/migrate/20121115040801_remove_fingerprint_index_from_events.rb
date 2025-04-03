# frozen_string_literal: true

class RemoveFingerprintIndexFromEvents < ActiveRecord::Migration
  def up
    remove_index "events", "fingerprint"
  end

  def down
    add_index "events", "fingerprint"
  end
end
