class AddGuardianFieldsToUserComplianceInfo < ActiveRecord::Migration[7.0]
  def change
    add_column :user_compliance_info, :guardian_dob_day, :integer
    add_column :user_compliance_info, :guardian_dob_month, :integer
    add_column :user_compliance_info, :guardian_dob_year, :integer
    add_column :user_compliance_info, :guardian_individual_tax_id, :text
  end
end
