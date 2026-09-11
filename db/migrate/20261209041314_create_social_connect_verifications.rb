# frozen_string_literal: true

# Main already records a future schema version, so this timestamp must sort
# after it; the time component is the real UTC authoring time, so parallel
# branches do not collide on a shared hand-picked value.
class CreateSocialConnectVerifications < ActiveRecord::Migration[7.1]
  def change
    create_table :social_connect_verifications do |t|
      t.bigint :user_id, null: false
      t.string :platform, null: false
      t.string :uid, null: false
      t.string :handle
      t.datetime :account_created_at
      t.bigint :follower_count
      t.bigint :post_count
      t.datetime :last_posted_at
      t.datetime :last_verified_at, null: false
      t.timestamps

      t.index [:user_id, :platform], unique: true
      # Deliberately non-unique: one social identity vouching for many Gumroad
      # accounts is the abuse signal reviewers need to SEE, not a state to reject.
      t.index [:platform, :uid]
    end
  end
end
