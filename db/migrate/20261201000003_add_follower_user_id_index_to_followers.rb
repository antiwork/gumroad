# frozen_string_literal: true

class AddFollowerUserIdIndexToFollowers < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :followers, [:follower_user_id, :deleted_at],
              name: "index_followers_on_follower_user_id_and_deleted_at"
  end
end
