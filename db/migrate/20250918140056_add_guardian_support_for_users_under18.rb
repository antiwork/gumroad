class AddGuardianSupportForUsersUnder18 < ActiveRecord::Migration[7.1]
  def change
    # Guardian columns already exist from previous partial migration
    # Only create the guardian_compliance_info_requests table for tracking guardian verification requirements
    create_table :guardian_compliance_info_requests, options: "DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_unicode_ci" do |t|
      t.references :user, null: false, foreign_key: true
      t.string :field_needed, null: false
      t.string :state, default: 'requested', null: false
      t.datetime :due_at
      t.datetime :provided_at
      t.text :json_data
      t.integer :flags, default: 0, null: false
      t.timestamps

      t.index [:user_id, :state], name: "idx_guardian_comp_req_user_state"
      t.index [:user_id, :field_needed], name: "idx_guardian_comp_req_user_field"
    end
  end
end
