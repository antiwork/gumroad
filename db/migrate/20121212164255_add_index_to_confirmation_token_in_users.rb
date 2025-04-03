# frozen_string_literal: true

class AddIndexToConfirmationTokenInUsers < ActiveRecord::Migration
  def change
    add_index :users, :confirmation_token
  end
end
