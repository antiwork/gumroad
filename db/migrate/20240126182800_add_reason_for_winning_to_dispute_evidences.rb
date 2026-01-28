# frozen_string_literal: true

class AddReasonForWinningToDisputeEvidences < ActiveRecord::Migration[4.2]
  def change
    add_column :dispute_evidences, :reason_for_winning, :text
  end
end
