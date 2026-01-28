# frozen_string_literal: true

class AddIndexForUserIdInEvents < ActiveRecord::Migration[4.2]
  def change
    add_index :events, :user_id
  end
end
