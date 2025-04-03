# frozen_string_literal: true

class AddDeletedAtToApiSessions < ActiveRecord::Migration
  def change
    add_column :api_sessions, :deleted_at, :datetime
  end
end
