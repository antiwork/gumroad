# frozen_string_literal: true

class AddIndexToCreditsOnUserIdAndCreatedAt < ActiveRecord::Migration[7.1]
  def change
    add_index :credits, [:user_id, :created_at, :id], name: "index_credits_on_user_id_and_created_at"
  end
end
