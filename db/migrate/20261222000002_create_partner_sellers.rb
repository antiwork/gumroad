# frozen_string_literal: true

class CreatePartnerSellers < ActiveRecord::Migration[8.1]
  def change
    create_table :partner_sellers do |t|
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
end
