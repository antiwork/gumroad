# frozen_string_literal: true

class AddIndexForUserIdInEvents < ActiveRecord::Migration
  def change
    add_index :events, :user_id
  end
end
