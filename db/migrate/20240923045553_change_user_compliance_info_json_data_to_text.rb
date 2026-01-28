# frozen_string_literal: true

class ChangeUserComplianceInfoJsonDataToText < ActiveRecord::Migration[4.2]
  def up
    change_column :user_compliance_info, :json_data, :text
  end

  def down
    change_column :user_compliance_info, :json_data, :string
  end
end
