# frozen_string_literal: true

class AddSynthesisAttemptsToWalksFreeTrials < ActiveRecord::Migration[7.1]
  def change
    add_column :walks_free_trials, :synthesis_attempts, :integer, null: false, default: 0
  end
end
