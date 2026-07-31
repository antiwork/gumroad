# frozen_string_literal: true

class AddGuardianToUserComplianceInfo < ActiveRecord::Migration[7.1]
  def change
    change_table :user_compliance_info, bulk: true do |t|
      t.bigint :guardian_id
      t.index :guardian_id
    end
  end
end
