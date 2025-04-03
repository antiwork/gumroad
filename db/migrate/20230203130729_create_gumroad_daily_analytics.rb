# frozen_string_literal: true

class CreateGumroadDailyAnalytics < ActiveRecord::Migration[7.0]
  def change
    create_table :gumroad_daily_analytics do |t|
      t.datetime :period_ended_at, null: false
      t.integer :gumroad_price_cents, null: false
      t.integer :gumroad_fee_cents, null: false
      t.integer :creators_with_sales, null: false
      t.integer :gumroad_discover_price_cents, null: false

      t.timestamps
      t.index :period_ended_at
    end
  end
end
