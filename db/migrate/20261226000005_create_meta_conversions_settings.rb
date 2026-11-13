# frozen_string_literal: true

class CreateMetaConversionsSettings < ActiveRecord::Migration[8.1]
  # Renumbered from 20261226000003, so databases that ran that version already have the table: up leaves
  # it alone, and down leaves it in place while that version is still recorded.
  SUPERSEDED_VERSION = "20261226000003"

  def up
    create_table :meta_conversions_settings, if_not_exists: true do |t|
      t.bigint :user_id, null: false
      t.text :access_token, null: false
      t.datetime :token_rejected_at
      t.timestamps

      t.index :user_id, unique: true
    end
  end

  def down
    return unless table_exists?(:meta_conversions_settings)
    return if superseded_version_applied?

    drop_table :meta_conversions_settings
  end

  private
    def superseded_version_applied?
      connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          ["SELECT 1 FROM schema_migrations WHERE version = ? LIMIT 1", SUPERSEDED_VERSION]
        )
      ).present?
    end
end
