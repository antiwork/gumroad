# frozen_string_literal: true

class AddWorkflowScheduleTokenToAffiliatesLinks < ActiveRecord::Migration[7.1]
  # The deployed schema is already at 20261207000000. Fresh databases skip lower versions.
  def change
    change_table :affiliates_links, bulk: true do |table|
      table.string :workflow_schedule_token
      table.index :workflow_schedule_token
    end
  end
end
