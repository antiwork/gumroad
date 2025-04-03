# frozen_string_literal: true

class CreateFollowJoinTable < ActiveRecord::Migration
  def change
    create_table :follows, id: false do |t|
      t.references :follower, null: false
      t.references :followed, null: false
    end

    add_index :follows, [:follower_id, :followed_id], unique: true
    add_index :follows, :followed_id
  end
end
