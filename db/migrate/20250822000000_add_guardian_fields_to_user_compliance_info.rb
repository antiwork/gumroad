class AddGuardianFieldsToUserComplianceInfo < ActiveRecord::Migration[7.1]
  def change
    # Add all guardian fields needed for users under 18
    add_column :user_compliance_info, :guardian_first_name, :string
    add_column :user_compliance_info, :guardian_last_name, :string
    add_column :user_compliance_info, :guardian_email, :string
    add_column :user_compliance_info, :guardian_phone, :string
    add_column :user_compliance_info, :guardian_street_address, :string
    add_column :user_compliance_info, :guardian_city, :string
    add_column :user_compliance_info, :guardian_state, :string
    add_column :user_compliance_info, :guardian_zip_code, :string
    add_column :user_compliance_info, :guardian_date_of_birth, :date
    add_column :user_compliance_info, :guardian_individual_tax_id, :binary
    add_column :user_compliance_info, :guardian_stripe_tos_accepted, :boolean, default: false
    add_column :user_compliance_info, :guardian_stripe_processing_tos_accepted, :boolean, default: false
    add_column :user_compliance_info, :guardian_verification_status, :string, default: "not_required"
  end
end
