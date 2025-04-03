# frozen_string_literal: true

class CreateApiSessions < ActiveRecord::Migration
  def change
    create_table :api_sessions do |t|
      t.integer :user_id
      t.string :token

      t.timestamps
    end

    add_index :api_sessions, :user_id
    add_index :api_sessions, :token
  end
end
