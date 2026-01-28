# frozen_string_literal: true

class AddVerticalsToUserComplianceInfo < ActiveRecord::Migration[4.2]
  def change
    add_column :user_compliance_info, :verticals, :text
  end
end
