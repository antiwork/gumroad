# frozen_string_literal: true

class AddUsernameIndexToUsers < ActiveRecord::Migration[4.2]
  def change
    add_index :users, :username
  end
end
