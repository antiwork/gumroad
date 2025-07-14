# frozen_string_literal: true

class AddGuardianSupportForUsersUnder18 < ActiveRecord::Migration[7.0]
  def change
    # Add guardian tax ID field to user_compliance_info table (encrypted binary field)
    add_column :user_compliance_info, :guardian_individual_tax_id, :binary

    # Create guardian_compliance_info_requests table for tracking guardian verification requirements
    create_table :guardian_compliance_info_requests, options: "DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_unicode_ci" do |t|
      t.references :user, null: false, foreign_key: true, type: :bigint
      t.string :field_needed, null: false
      t.datetime :due_at, precision: nil
      t.string :state, default: 'requested', null: false
      t.datetime :provided_at, precision: nil
      t.text :json_data
      t.integer :flags, default: 0, null: false
      t.string :guardian_person_id
      t.string :external_id

      t.timestamps precision: nil, null: false
    end

    # Add indexes for guardian_compliance_info_requests
    add_index :guardian_compliance_info_requests, [:user_id, :state], name: "index_guardian_compliance_requests_on_user_id_and_state"
    add_index :guardian_compliance_info_requests, :field_needed, name: "index_guardian_compliance_requests_on_field_needed"
    add_index :guardian_compliance_info_requests, :external_id, unique: true, name: "index_guardian_compliance_requests_on_external_id"
    add_index :guardian_compliance_info_requests, :guardian_person_id, name: "index_guardian_compliance_requests_on_person_id"
  end
end

