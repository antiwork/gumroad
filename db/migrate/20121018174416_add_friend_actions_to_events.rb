# frozen_string_literal: true

class AddFriendActionsToEvents < ActiveRecord::Migration[4.2]
  def change
    add_column :events, :friend_actions, :text
  end
end
