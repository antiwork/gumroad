# frozen_string_literal: true

class RemoveIsBusinessPubliclyTradedFromUserComplianceInfo < ActiveRecord::Migration[7.0]
  def change
    remove_column :user_compliance_info, :is_business_publicly_traded, :boolean
  end
end
