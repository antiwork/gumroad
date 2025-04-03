# frozen_string_literal: true

class AddLastActiveSessionsInvalidatedAtToUsers < ActiveRecord::Migration[6.1]
  def up
    # Using raw SQL due to a bug in departure gem: https://github.com/gumroad/web/pull/17299#issuecomment-786054996
    execute <<~SQL
      ALTER TABLE users
        ADD COLUMN last_active_sessions_invalidated_at DATETIME
    SQL
  end

  def down
    remove_column :users, :last_active_sessions_invalidated_at
  end
end
