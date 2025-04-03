# frozen_string_literal: true

class AddIndexToUserIdOnSubscriptions < ActiveRecord::Migration
  def change
    add_index :subscriptions, :user_id
  end
end
