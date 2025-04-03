# frozen_string_literal: true

class AddBannedToBlockedIps < ActiveRecord::Migration
  def change
    add_column :blocked_ips, :banned, :boolean
  end
end
