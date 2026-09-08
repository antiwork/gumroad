# frozen_string_literal: true

# Timestamp sorts after main's future schema version; real UTC authoring time
# so parallel branches do not collide on a hand-picked value.
class AddSupersededAtToSocialConnectVerifications < ActiveRecord::Migration[7.1]
  def up
    change_table :social_connect_verifications, bulk: true do |t|
      t.datetime :superseded_at

      # Reconnecting to a different identity keeps the old row as shared-identity
      # veto evidence, so a user may hold several rows per platform; only the
      # same identity is deduped.
      t.remove_index [:user_id, :platform], unique: true
      t.index [:user_id, :platform]
      t.index [:user_id, :platform, :uid], unique: true, name: "index_scv_on_user_id_platform_and_uid"
    end
  end

  # Restoring unique [user_id, platform] would fail once superseded history exists.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
