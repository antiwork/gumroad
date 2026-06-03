# frozen_string_literal: true

class AddIndexToCreditsOnUserIdAndCreatedAt < ActiveRecord::Migration[7.1]
  def change
    add_index :credits, [:user_id, :created_at, :id]
  end
end
