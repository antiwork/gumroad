# frozen_string_literal: true

class AddReasonForWinningToDisputeEvidences < ActiveRecord::Migration[7.0]
  def change
    add_column :dispute_evidences, :reason_for_winning, :text
  end
end
