# frozen_string_literal: true

class AddBannedAtToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :banned_at, :timestamp
  end
end
