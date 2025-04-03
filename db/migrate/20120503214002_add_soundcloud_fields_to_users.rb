# frozen_string_literal: true

class AddSoundcloudFieldsToUsers < ActiveRecord::Migration
  def change
    add_column :users, :soundcloud_username, :string
    add_column :users, :soundcloud_token, :string
  end
end
