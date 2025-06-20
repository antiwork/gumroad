class AddGuardianIndividualTaxIdToUserComplianceInfo < ActiveRecord::Migration[7.1]
  def change
    add_column :user_compliance_info, :guardian_individual_tax_id, :text
  end
end
