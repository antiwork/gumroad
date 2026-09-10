# frozen_string_literal: true

# users is frozen (docs/migrations.md); live TikTok identity lives here so
# connect/unlink does not ALTER that table. The SocialConnectVerification row
# stays as dormant risk evidence after disconnect.
class CreateUserTiktokIdentities < ActiveRecord::Migration[7.1]
  def change
    create_table :user_tiktok_identities do |t|
      t.references :user, null: false, index: { unique: true }
      t.string :tiktok_open_id, null: false
      t.string :handle
      t.timestamps

      t.index :tiktok_open_id
    end
  end
end
