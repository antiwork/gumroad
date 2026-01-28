# frozen_string_literal: true

class AddBannedToBlockedIps < ActiveRecord::Migration[4.2]
  def change
    add_column :blocked_ips, :banned, :boolean
  end
end
