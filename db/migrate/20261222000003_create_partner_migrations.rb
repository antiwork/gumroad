# frozen_string_literal: true

class CreatePartnerMigrations < ActiveRecord::Migration[8.1]
  # Partner user IDs and Nano IDs are compared byte for byte; the table's collation ignores case,
  # accents and trailing spaces.
  EXACT_COLLATION = "utf8mb4_0900_bin"
  # Renumbered after main took 20261221000001. A preview database that ran the old number already has
  # the table, so up skips it, and down keeps it while the old number is recorded.
  SUPERSEDED_VERSION = "20261221000003"

  def up
    create_table :partner_migrations, if_not_exists: true do |t|
      t.integer :oauth_application_id, null: false
      t.string :external_user_id, null: false, collation: EXACT_COLLATION
      t.string :public_id, limit: 21, null: false, collation: EXACT_COLLATION
      t.string :code_digest, null: false
      t.json :products, null: false
      t.json :results
      t.string :status, null: false, default: "pending"
      t.bigint :user_id
      t.datetime :expires_at, null: false
      t.datetime :claimed_at
      t.datetime :completed_at
      t.string :failure_reason
      t.integer :resumes_count, null: false, default: 0
      t.string :email
      t.json :profile
      t.boolean :account_created, null: false, default: false
      t.string :account_setup_token_digest
      t.string :account_setup_password_digest
      t.datetime :account_setup_sent_at
      t.integer :account_setup_emails_count, null: false, default: 0
      t.datetime :notified_at
      t.string :notification_failed_email
      t.datetime :failure_notified_at
      t.timestamps

      t.index :public_id, unique: true
      t.index :code_digest, unique: true
      t.index [:oauth_application_id, :external_user_id], name: "index_partner_migrations_on_application_and_external_user"
      t.index :user_id
      t.index :account_setup_token_digest, unique: true
      t.index [:notified_at, :completed_at]
      t.index [:status, :updated_at]
    end
    # A preview database that ran the old number before this column was added to it skips the table above.
    add_column :partner_migrations, :account_setup_password_digest, :string, if_not_exists: true
  end

  def down
    return if select_value("SELECT 1 FROM schema_migrations WHERE version = #{connection.quote(SUPERSEDED_VERSION)}").present?

    drop_table :partner_migrations
  end
end
