# frozen_string_literal: true

class AddFacebookAccessTokenToUsers < ActiveRecord::Migration
  def change
    add_column :users, :facebook_access_token, :string
  end
end
