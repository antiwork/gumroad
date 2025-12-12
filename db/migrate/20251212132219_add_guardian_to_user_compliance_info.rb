# frozen_string_literal: true

class AddGuardianToUserComplianceInfo < ActiveRecord::Migration[7.1]
  def change
    add_reference :user_compliance_info, :guardian, foreign_key: true, index: true
  end
end
