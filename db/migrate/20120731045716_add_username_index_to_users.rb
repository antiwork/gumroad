# frozen_string_literal: true

class AddUsernameIndexToUsers < ActiveRecord::Migration
  def change
    add_index :users, :username
  end
end
