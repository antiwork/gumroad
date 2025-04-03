# frozen_string_literal: true

class UserFacebookUid < ActiveRecord::Migration
  def up
    add_column :users, :facebook_uid, :string
    add_index :users, :facebook_uid
  end

  def down
    remove_index :users, :facebook_uid
    remove_column :users, :facebook_uid, :string
  end
end
