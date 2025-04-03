# frozen_string_literal: true

class DropFacebookProfileFromUsers < ActiveRecord::Migration[6.1]
  def change
    remove_column :users, :facebook_profile, :string
  end
end
