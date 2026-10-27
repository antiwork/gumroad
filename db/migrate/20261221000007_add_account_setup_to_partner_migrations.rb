# frozen_string_literal: true

class AddAccountSetupToPartnerMigrations < ActiveRecord::Migration[8.1]
  def change
    change_table :partner_migrations, bulk: true do |t|
      t.string :email
      t.json :profile
      t.boolean :account_created, default: false, null: false
      t.string :account_setup_token_digest
      t.datetime :account_setup_sent_at
      t.integer :account_setup_emails_count, default: 0, null: false
      t.index :account_setup_token_digest, unique: true
    end
  end
end
