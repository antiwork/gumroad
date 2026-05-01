# frozen_string_literal: true

class CreateAdminApiAuditLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :admin_api_audit_logs do |t|
      t.bigint :actor_user_id, null: false
      t.bigint :admin_api_token_id, null: false
      t.string :action, null: false
      t.string :target_type
      t.bigint :target_id
      t.string :target_external_id
      t.string :route, null: false
      t.string :http_method, null: false
      t.json :params_snapshot
      t.string :request_id
      t.integer :response_status
      t.string :error_class
      t.datetime :created_at, null: false

      t.index [:actor_user_id, :created_at]
      t.index [:admin_api_token_id, :created_at]
      t.index [:target_type, :target_id, :created_at]
      t.index :created_at
    end
  end
end
