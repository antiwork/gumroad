# frozen_string_literal: true

class AddVerifiedToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :verified, :boolean
  end
end
