# frozen_string_literal: true

class CreatePartnerSellers < ActiveRecord::Migration[8.1]
  # Renumbered each time main took a version this branch had used. A preview database that ran an old
  # number already has the table, so up skips it, and down keeps it while an old number is recorded.
  SUPERSEDED_VERSIONS = %w[20261221000002 20261222000002 20261223000007].freeze

  def up
    create_table :partner_sellers, if_not_exists: true do |t|
      t.integer :oauth_application_id, null: false
      t.bigint :user_id, null: false
      # Partner user IDs are opaque, so "aB3x" and "Ab3X", or "id" and "id ", are different users.
      # utf8mb4_0900_bin compares the exact bytes; the table's collation ignores case, accents and trailing spaces.
      t.string :external_user_id, null: false, collation: "utf8mb4_0900_bin"
      t.datetime :migrated_at
      t.datetime :deleted_at
      t.timestamps
      t.index [:oauth_application_id, :external_user_id], unique: true, name: "index_partner_sellers_on_application_and_external_user"
      t.index [:oauth_application_id, :user_id], unique: true, name: "index_partner_sellers_on_application_and_user"
      t.index :user_id
    end
  end

  def down
    return if select_value("SELECT 1 FROM schema_migrations WHERE version IN (#{SUPERSEDED_VERSIONS.map { connection.quote(_1) }.join(", ")})").present?

    drop_table :partner_sellers
  end
end
