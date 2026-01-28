# frozen_string_literal: true

class AddRiskScoreToLinks < ActiveRecord::Migration[4.2]
  def change
    add_column :links, :risk_score, :integer
  end
end
