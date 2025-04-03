# frozen_string_literal: true

class RemoveFollowerIdFromFollows < ActiveRecord::Migration
  def change
    remove_column :follows, :follower_id
  end
end
