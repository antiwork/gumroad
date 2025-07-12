# frozen_string_literal: true

class CreateGuardianComplianceInfoRequests < ActiveRecord::Migration[7.0]
  def change
    create_table :guardian_compliance_info_requests, options: "DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_unicode_ci" do |t|
      t.references :user, null: false, foreign_key: true, type: :bigint
      t.string :field_needed, null: false
      t.datetime :due_at, precision: nil
      t.string :state, default: 'requested', null: false
      t.datetime :provided_at, precision: nil
      t.text :json_data
      t.integer :flags, default: 0, null: false
      t.string :guardian_person_id # Store Stripe person ID
      t.string :external_id, null: false

      t.timestamps precision: nil, null: false
    end

    add_index :guardian_compliance_info_requests, [:user_id, :state], name: "index_guardian_compliance_requests_on_user_id_and_state"
    add_index :guardian_compliance_info_requests, :field_needed, name: "index_guardian_compliance_requests_on_field_needed"
    add_index :guardian_compliance_info_requests, :external_id, unique: true, name: "index_guardian_compliance_requests_on_external_id"
    add_index :guardian_compliance_info_requests, :guardian_person_id, name: "index_guardian_compliance_requests_on_person_id"
  end
end
