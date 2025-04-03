# frozen_string_literal: true

class AddRiskScoreToLinks < ActiveRecord::Migration
  def change
    add_column :links, :risk_score, :integer
  end
end
