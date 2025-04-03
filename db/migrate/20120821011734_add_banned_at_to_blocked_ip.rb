# frozen_string_literal: true

class AddBannedAtToBlockedIp < ActiveRecord::Migration
  def change
    add_column :blocked_ips, :banned_at, :timestamp
  end
end
