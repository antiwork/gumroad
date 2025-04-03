# frozen_string_literal: true

class AddBannedAtAndAutobannedAtToUsers < ActiveRecord::Migration
  def change
    add_column :users, :banned_at, :timestamp
    add_column :users, :autobanned_at, :timestamp
  end
end
