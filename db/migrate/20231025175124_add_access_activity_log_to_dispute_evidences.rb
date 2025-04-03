# frozen_string_literal: true

class AddAccessActivityLogToDisputeEvidences < ActiveRecord::Migration[7.0]
  def change
    add_column :dispute_evidences, :access_activity_log, :text
  end
end
