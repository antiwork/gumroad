# frozen_string_literal: true

class DropFacebookProfileFromUsers < ActiveRecord::Migration[4.2]
  def change
    remove_column :users, :facebook_profile, :string
  end
end
