# frozen_string_literal: true

class CreateWalksAppAttestKeys < ActiveRecord::Migration[7.1]
  def change
    create_table :walks_app_attest_keys do |t|
      t.string  :key_id,      null: false, limit: 64
      t.binary  :public_key,  null: false, limit: 200
      t.bigint  :counter,     null: false, default: 0
      t.string  :environment, null: false, limit: 16
      t.datetime :attested_at, null: false, precision: 6
      t.datetime :last_used_at, precision: 6
      t.timestamps precision: 6

      t.index :key_id, unique: true
    end
  end
end
