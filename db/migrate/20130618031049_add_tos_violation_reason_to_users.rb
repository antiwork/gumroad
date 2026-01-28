# frozen_string_literal: true

class AddTosViolationReasonToUsers < ActiveRecord::Migration[4.2]
  def up
    add_column :users, :tos_violation_reason, :string
  end

  def down
    remove_column :users, :tos_violation_reason
  end
end
