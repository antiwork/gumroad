# frozen_string_literal: true

class AddFacebookColumnToUsers < ActiveRecord::Migration
  def up
    add_column :users, :facebook_profile, :string
    add_column :users, :facebook_gender, :string
    add_column :users, :facebook_timezone, :string
    add_column :users, :facebook_locale, :string
    add_column :users, :facebook_verified, :string
    add_column :users, :facebook_pic_large, :string
    add_column :users, :facebook_pic_square, :string
  end

  def down
    remove_column :users, :facebook_profile
    remove_column :users, :facebook_gender
    remove_column :users, :facebook_timezone
    remove_column :users, :facebook_locale
    remove_column :users, :facebook_verified
    remove_column :users, :facebook_pic_large
    remove_column :users, :facebook_pic_square
  end
end
