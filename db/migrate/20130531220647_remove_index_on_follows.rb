# frozen_string_literal: true

class RemoveIndexOnFollows < ActiveRecord::Migration
  def change
    remove_index :follows, name:  "index_follows_on_follower_id_and_followed_id"
    remove_index :follows, name:  "index_follows_on_followed_id"
  end
end
