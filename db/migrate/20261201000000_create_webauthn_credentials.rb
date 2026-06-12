# frozen_string_literal: true

class CreateWebauthnCredentials < ActiveRecord::Migration[7.1]
  def change
    create_table :webauthn_credentials do |t|
      t.references :user, null: false, index: true
      t.text :webauthn_id, null: false
      t.string :webauthn_id_sha256, null: false, limit: 64
      t.text :public_key, null: false
      t.bigint :sign_count, null: false, default: 0
      t.string :nickname, null: false
      t.datetime :last_used_at
      t.timestamps

      t.index :webauthn_id_sha256, unique: true
    end
  end
end
