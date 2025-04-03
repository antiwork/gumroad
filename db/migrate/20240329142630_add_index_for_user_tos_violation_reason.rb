# frozen_string_literal: true

class AddIndexForUserTosViolationReason < ActiveRecord::Migration[7.1]
  def change
    add_index :users, :tos_violation_reason
  end
end
