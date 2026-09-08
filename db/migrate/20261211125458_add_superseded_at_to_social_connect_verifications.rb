# frozen_string_literal: true

# Main already records a future schema version, so this timestamp must sort
# after it; the time component is the real UTC authoring time, so parallel
# branches do not collide on a shared hand-picked value.
class AddSupersededAtToSocialConnectVerifications < ActiveRecord::Migration[7.1]
  def change
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
end
