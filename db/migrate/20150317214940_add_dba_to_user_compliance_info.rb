# frozen_string_literal: true

class AddDbaToUserComplianceInfo < ActiveRecord::Migration[4.2]
  def change
    add_column :user_compliance_info, :dba, :string
  end
end
