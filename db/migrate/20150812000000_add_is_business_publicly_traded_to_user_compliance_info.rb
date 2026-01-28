# frozen_string_literal: true

class AddIsBusinessPubliclyTradedToUserComplianceInfo < ActiveRecord::Migration[4.2]
  def change
    add_column :user_compliance_info, :is_business_publicly_traded, :boolean
  end
end
