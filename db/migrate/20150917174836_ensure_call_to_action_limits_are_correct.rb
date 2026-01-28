# frozen_string_literal: true

class EnsureCallToActionLimitsAreCorrect < ActiveRecord::Migration[4.2]
  def change
    change_column(:installments, :call_to_action_text, :string, limit: 2083)
    change_column(:installments, :call_to_action_url,  :string, limit: 2083)
  end
end
