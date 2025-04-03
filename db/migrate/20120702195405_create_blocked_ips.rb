# frozen_string_literal: true

class CreateBlockedIps < ActiveRecord::Migration
  def change
    create_table :blocked_ips do |t|
      t.string :ip_address

      t.timestamps
    end
  end
end
