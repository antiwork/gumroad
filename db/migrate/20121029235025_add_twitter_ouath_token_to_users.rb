# frozen_string_literal: true

class AddTwitterOuathTokenToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :twitter_oauth_token, :string
  end
end
