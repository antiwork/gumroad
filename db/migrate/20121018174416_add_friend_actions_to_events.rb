# frozen_string_literal: true

class AddFriendActionsToEvents < ActiveRecord::Migration
  def change
    add_column :events, :friend_actions, :text
  end
end
