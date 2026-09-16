# frozen_string_literal: true

class CreateMarketingActions < ActiveRecord::Migration[7.1]
  def change
    create_table :marketing_actions do |t|
      t.references :user, null: false
      t.references :link, null: false
      t.references :utm_link
      t.string :channel, null: false
      t.string :status, null: false, default: "recommended"
      t.string :idempotency_key, null: false, index: { unique: true }
      t.text :copy
      t.string :external_post_id
      t.string :external_url
      t.string :error_code
      t.datetime :approved_at
      t.datetime :posted_at
      t.timestamps

      t.index [:link_id, :channel, :status]
    end
  end
end
