# frozen_string_literal: true

class AddDeletedAtToApiSessions < ActiveRecord::Migration[4.2]
  def change
    add_column :api_sessions, :deleted_at, :datetime
  end
end
