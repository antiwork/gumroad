# frozen_string_literal: true

class DropWalksTables < ActiveRecord::Migration[7.1]
  def up
    drop_table :walks_free_trials, if_exists: true
    drop_table :walks_app_attest_keys, if_exists: true
  end

  def down
    create_table :walks_app_attest_keys do |t|
      t.string :key_id, null: false, limit: 64
      t.binary :public_key, null: false, limit: 200
      t.bigint :counter, null: false, default: 0
      t.string :environment, null: false, limit: 16
      t.datetime :attested_at, null: false, precision: 6
      t.datetime :last_used_at, precision: 6
      t.timestamps precision: 6

      t.index :key_id, unique: true
    end

    create_table :walks_free_trials do |t|
      t.bigint :walks_app_attest_key_id, null: false
      t.datetime :consumed_at, null: false
      t.integer :synthesis_attempts, null: false, default: 0
      t.timestamps precision: 6

      t.index :walks_app_attest_key_id, unique: true
    end
  end
end
