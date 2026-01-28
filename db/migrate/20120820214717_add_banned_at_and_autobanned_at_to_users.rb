# frozen_string_literal: true

class AddBannedAtAndAutobannedAtToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :banned_at, :timestamp
    add_column :users, :autobanned_at, :timestamp
  end
end
