# frozen_string_literal: true

class FixTwitterUserId < ActiveRecord::Migration
  def up
    change_column :users, :twitter_user_id, :string
  end

  def down
    change_column :users, :twitter_user_id, :integer
  end
end
