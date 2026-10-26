# frozen_string_literal: true

class CreatePartnerMigrations < ActiveRecord::Migration[8.1]
  def change
    create_table :partner_migrations do |t|
      t.integer :oauth_application_id, null: false
      t.string :external_user_id, null: false
      t.string :code_digest, null: false
      t.json :products, null: false
      t.json :results
      t.string :status, null: false, default: "pending"
      t.bigint :user_id
      t.datetime :expires_at, null: false
      t.datetime :claimed_at
      t.datetime :completed_at
      t.string :failure_reason
      t.timestamps

      t.index :code_digest, unique: true
      t.index [:oauth_application_id, :external_user_id], name: "index_partner_migrations_on_application_and_external_user"
      t.index :user_id
    end
  end
end
