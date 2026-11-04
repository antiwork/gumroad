# frozen_string_literal: true

class CreateProductBuildPlaySessions < ActiveRecord::Migration[8.1]
  def change
    create_table :product_build_play_sessions do |t|
      t.bigint :product_id, null: false
      t.bigint :product_build_id, null: false
      t.bigint :purchase_id, null: false
      t.datetime :started_at, null: false
      t.datetime :last_heartbeat_at, null: false
      t.bigint :replacement_id
      t.timestamps

      t.index [:product_id, :started_at]
      t.index :product_build_id
      t.index :purchase_id
    end
  end
end
