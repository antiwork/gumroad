# frozen_string_literal: true

class FixTwitterUserId < ActiveRecord::Migration[4.2]
  def up
    change_column :users, :twitter_user_id, :string
  end

  def down
    change_column :users, :twitter_user_id, :integer
  end
end
