# frozen_string_literal: true

class AddDbaToUserComplianceInfo < ActiveRecord::Migration
  def change
    add_column :user_compliance_info, :dba, :string
  end
end
