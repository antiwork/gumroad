# frozen_string_literal: true

# One row per newsletter seller: the reviewed plan, migration progress and retirement of the old
# newsletter. While a row exists, that seller's follower opt-outs also write Feature announcements opt-outs.
class CreateFeatureAnnouncementNewsletterCutovers < ActiveRecord::Migration[8.1]
  def change
    create_table :feature_announcement_newsletter_cutovers do |t|
      t.bigint :seller_id, null: false
      t.string :state, limit: 16, null: false
      t.datetime :cutoff_at, null: false
      t.json :counts
      t.integer :eligible_count, null: false, default: 0
      t.integer :migrated_count, null: false, default: 0
      t.bigint :cursor_follower_id, null: false, default: 0
      t.string :error
      t.datetime :retired_at
      t.timestamps

      t.index :seller_id, unique: true
    end
  end
end
