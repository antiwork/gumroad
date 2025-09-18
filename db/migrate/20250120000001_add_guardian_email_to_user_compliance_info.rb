# frozen_string_literal: true

class AddGuardianEmailToUserComplianceInfo < ActiveRecord::Migration[7.1]
  def change
    add_column :user_compliance_info, :guardian_email, :string
  end
end
