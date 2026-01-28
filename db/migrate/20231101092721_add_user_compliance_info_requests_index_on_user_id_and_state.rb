# frozen_string_literal: true

class AddUserComplianceInfoRequestsIndexOnUserIdAndState < ActiveRecord::Migration[4.2]
  def change
    add_index :user_compliance_info_requests, [:user_id, :state]
  end
end
