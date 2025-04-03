# frozen_string_literal: true

class AddBannedAtToLinks < ActiveRecord::Migration
  def change
    add_column :links, :banned_at, :timestamp
  end
end
