# frozen_string_literal: true

class CreatePartnerSellers < ActiveRecord::Migration[8.1]
  # Renumbered after main took 20261221000001. A preview database that ran the old number already has
  # the table, so up skips it, and down keeps it while the old number is recorded.
  SUPERSEDED_VERSION = "20261221000002"

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
    return if select_value("SELECT 1 FROM schema_migrations WHERE version = #{connection.quote(SUPERSEDED_VERSION)}").present?

    drop_table :partner_sellers
  end
end
