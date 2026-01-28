# frozen_string_literal: true

class AddAccessActivityLogToDisputeEvidences < ActiveRecord::Migration[4.2]
  def change
    add_column :dispute_evidences, :access_activity_log, :text
  end
end
