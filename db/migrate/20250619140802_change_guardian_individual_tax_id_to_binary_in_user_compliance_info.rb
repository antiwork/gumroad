class ChangeGuardianIndividualTaxIdToBinaryInUserComplianceInfo < ActiveRecord::Migration[7.1]
  def up
    change_column :user_compliance_info, :guardian_individual_tax_id, :binary
  end

  def down
    change_column :user_compliance_info, :guardian_individual_tax_id, :text
  end
end
