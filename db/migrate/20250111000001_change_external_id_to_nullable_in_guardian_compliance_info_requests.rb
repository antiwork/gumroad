# frozen_string_literal: true

class ChangeExternalIdToNullableInGuardianComplianceInfoRequests < ActiveRecord::Migration[7.0]
  def change
    change_column_null :guardian_compliance_info_requests, :external_id, true
  end
end
