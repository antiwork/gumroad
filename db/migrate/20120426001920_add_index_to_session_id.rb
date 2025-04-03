# frozen_string_literal: true

class AddIndexToSessionId < ActiveRecord::Migration
  def up
    add_index :purchases, :session_id
  end

  def down
    remove_index :purchases, :session_id
  end
end
