# frozen_string_literal: true

class AddUserOauthInformation < ActiveRecord::Migration
  def up
    add_column :users, :provider, :string
    add_column :users, :twitter_user_id, :integer
    add_index :users, [:twitter_user_id]
  end

  def down
    remove_column :users, :provider, :string
    remove_column :users, :twitter_user_id
    remove_index :users, [:twitter_user_id]
  end
end
