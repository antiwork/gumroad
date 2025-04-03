# frozen_string_literal: true

class AddIsBusinessPubliclyTradedToUserComplianceInfo < ActiveRecord::Migration
  def change
    add_column :user_compliance_info, :is_business_publicly_traded, :boolean
  end
end
