# frozen_string_literal: true

class AddFacebookMetaTagToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :facebook_meta_tag, :string
  end
end
