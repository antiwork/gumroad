# frozen_string_literal: true

class AddResolutionFieldsToDisputeEvidences < ActiveRecord::Migration[7.0]
  def change
    change_table :dispute_evidences, bulk: true do |t|
      t.datetime :resolved_at
      t.string :resolution, default: "unknown"
      t.string :error_message
      t.index :resolved_at
    end
  end
end
