# frozen_string_literal: true

require "digest"

class CreateAdminApiTokens < ActiveRecord::Migration[7.1]
  TOKEN_ALPHABET = "_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  def up
    create_table :admin_api_tokens do |t|
      t.string :external_id, null: false, limit: 21
      t.bigint :actor_user_id, null: false
      t.string :token_hash, null: false, limit: 64
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.datetime :expires_at
      t.timestamps

      t.index :external_id, unique: true
      t.index :token_hash, unique: true
      t.index :actor_user_id
      t.index :revoked_at
      t.index :expires_at
    end

    seed_legacy_admin_token!
  end

  def down
    drop_table :admin_api_tokens
  end

  private
    def seed_legacy_admin_token!
      legacy_token = GlobalConfig.get("INTERNAL_ADMIN_API_TOKEN").to_s
      if legacy_token.blank?
        say "INTERNAL_ADMIN_API_TOKEN is blank; skipping legacy admin token seed. " \
            "Set it and run AdminApiToken.seed_legacy_admin_token! before using the shared token."
        return
      end

      now = Time.current
      execute <<~SQL.squish
        INSERT INTO admin_api_tokens (external_id, actor_user_id, token_hash, created_at, updated_at)
        VALUES (
          #{quote(generate_token(21))},
          #{GUMROAD_ADMIN_ID},
          #{quote(Digest::SHA256.hexdigest(legacy_token))},
          #{quote(now)},
          #{quote(now)}
        )
      SQL
    end

    def generate_token(length)
      Array.new(length) { TOKEN_ALPHABET[SecureRandom.random_number(TOKEN_ALPHABET.length)] }.join
    end

    def quote(value)
      connection.quote(value)
    end
end
