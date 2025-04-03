# frozen_string_literal: true

class AddFacebookMetaTagToUsers < ActiveRecord::Migration[6.1]
  def change
    add_column :users, :facebook_meta_tag, :string
  end
end
