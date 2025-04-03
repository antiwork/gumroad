# frozen_string_literal: true

class RemoveSubmittedAtOnDisputeEvidences < ActiveRecord::Migration[7.0]
  def up
    remove_column :dispute_evidences, :submitted_at
  end

  def down
    change_table :dispute_evidences, bulk: true do |t|
      t.datetime :submitted_at
      t.index :submitted_at
    end
  end
end
