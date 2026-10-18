# frozen_string_literal: true

# A missing row means not subscribed. Opt-outs are kept as subscribed: false rows so a
# later migration insert can never resubscribe someone.
class CreateFeatureAnnouncementSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :feature_announcement_subscriptions do |t|
      t.bigint :user_id, null: false
      t.boolean :subscribed, null: false
      t.integer :version, null: false, default: 1
      t.string :source, limit: 32, null: false
      t.timestamps

      t.index :user_id, unique: true
    end
  end
end
