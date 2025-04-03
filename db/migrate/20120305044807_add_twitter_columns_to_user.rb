# frozen_string_literal: true

class AddTwitterColumnsToUser < ActiveRecord::Migration
  def up
    add_column :users, :bio, :string
    add_column :users, :twitter_handle, :string
    add_column :users, :twitter_verified, :string
    add_column :users, :twitter_location, :string
    add_column :users, :twitter_pic, :string
  end

  def down
    remove_column :users, :bio
    remove_column :users, :twitter_handle
    remove_column :users, :twitter_verified
    remove_column :users, :twitter_location
    remove_column :users, :twitter_pic
  end
end
