# frozen_string_literal: true

class EnsurePingSigningSettings < ActiveRecord::Migration[8.1]
  # Supersedes 20261225000003, which this branch first used for a `users` column and then for this
  # table. A preview database that ran either keeps that version recorded, so up skips a table that
  # already exists, and down keeps it while 20261225000003 is recorded.
  SUPERSEDED_VERSION = "20261225000003"

  def up
    return if table_exists?(:ping_signing_settings)

    create_table :ping_signing_settings do |t|
      t.bigint :user_id, null: false
      t.string :secret, null: false
      t.timestamps

      t.index :user_id, unique: true
    end
  end

  def down
    return if select_value("SELECT 1 FROM schema_migrations WHERE version = #{quote(SUPERSEDED_VERSION)}")

    drop_table :ping_signing_settings
  end
end
