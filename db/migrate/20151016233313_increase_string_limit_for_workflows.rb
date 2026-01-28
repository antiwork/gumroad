# frozen_string_literal: true

class IncreaseStringLimitForWorkflows < ActiveRecord::Migration[4.2]
  def change
    change_column(:workflows, :name, :string, limit: 1024)
  end
end
