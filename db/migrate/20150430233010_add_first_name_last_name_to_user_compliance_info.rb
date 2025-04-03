# frozen_string_literal: true

class AddFirstNameLastNameToUserComplianceInfo < ActiveRecord::Migration
  def change
    add_column :user_compliance_info, :first_name, :string
    add_column :user_compliance_info, :last_name, :string
  end
end
