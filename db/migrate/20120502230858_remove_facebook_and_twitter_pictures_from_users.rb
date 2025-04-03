# frozen_string_literal: true

class RemoveFacebookAndTwitterPicturesFromUsers < ActiveRecord::Migration
  def up
    remove_column :users, :facebook_pic_large
    remove_column :users, :facebook_pic_square
    remove_column :users, :twitter_pic
  end

  def down
    add_column :users, :facebook_pic_large, :string
    add_column :users, :facebook_pic_square, :string
    add_column :users, :twitter_pic, :string
  end
end
