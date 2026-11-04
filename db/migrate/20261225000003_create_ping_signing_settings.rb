# frozen_string_literal: true

# The Ping signing secret cannot be a `users` column: CONTRIBUTING forbids schema changes on `users`
# and `purchases` (too large; migrations there block deployments), so new per-seller data goes in its
# own table. No foreign key, for the same guide's reason (see CONTRIBUTING.md, "Migrations").
class CreatePingSigningSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :ping_signing_settings do |t|
      t.bigint :user_id, null: false
      t.string :secret, null: false
      t.timestamps

      t.index :user_id, unique: true
    end
  end
end
