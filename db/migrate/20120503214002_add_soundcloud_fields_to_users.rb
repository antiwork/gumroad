# frozen_string_literal: true

class AddSoundcloudFieldsToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :soundcloud_username, :string
    add_column :users, :soundcloud_token, :string
  end
end
