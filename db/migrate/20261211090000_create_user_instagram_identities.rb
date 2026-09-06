# frozen_string_literal: true

# Main already records a future schema version, so this timestamp must sort
# after it (same pattern as user_youtube_identities). users is frozen
# (docs/migrations.md); live Instagram identity lives here so connect/unlink
# does not ALTER that table. The SocialConnectVerification row stays as dormant
# risk evidence after disconnect.
class CreateUserInstagramIdentities < ActiveRecord::Migration[7.1]
  def change
    create_table :user_instagram_identities do |t|
      t.references :user, null: false, index: { unique: true }
      t.string :instagram_user_id, null: false
      t.string :handle
      t.timestamps

      t.index :instagram_user_id
    end
  end
end
