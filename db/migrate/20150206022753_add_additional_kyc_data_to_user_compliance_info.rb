# frozen_string_literal: true

class AddAdditionalKycDataToUserComplianceInfo < ActiveRecord::Migration
  def change
    add_column :user_compliance_info, :business_name, :string
    add_column :user_compliance_info, :business_street_address, :string
    add_column :user_compliance_info, :business_city, :string
    add_column :user_compliance_info, :business_state, :string
    add_column :user_compliance_info, :business_zip_code, :string
    add_column :user_compliance_info, :business_country, :string
    add_column :user_compliance_info, :business_type, :string

    add_column :user_compliance_info, :business_tax_id, :binary
    add_column :user_compliance_info, :business_tax_id_type, :string, default: "ein"

    rename_column :user_compliance_info, :tax_id, :individual_tax_id
    add_column :user_compliance_info, :individual_tax_id_type, :string, default: "ssn"

    add_column :user_compliance_info, :birthday, :date
    add_column :user_compliance_info, :deleted_at, :datetime
  end
end
