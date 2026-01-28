# frozen_string_literal: true

class AddIsDeveloperToUsers < ActiveRecord::Migration[4.2]
  def change
    add_column :users, :is_developer, :boolean, default: false
  end
end
