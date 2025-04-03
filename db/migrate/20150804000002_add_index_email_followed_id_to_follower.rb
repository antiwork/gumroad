# frozen_string_literal: true

class AddIndexEmailFollowedIdToFollower < ActiveRecord::Migration
  def up
    remove_index :followers, name: "index_follows_on_email_and_followed_id"
    add_index :followers, [:email, :followed_id], unique: true
  end

  def down
    remove_index :followers, [:email, :followed_id]
    add_index :followers, [:email, :followed_id], name: "index_follows_on_email_and_followed_id"
  end
end
