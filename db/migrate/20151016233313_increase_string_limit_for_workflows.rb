# frozen_string_literal: true

class IncreaseStringLimitForWorkflows < ActiveRecord::Migration
  def change
    change_column(:workflows, :name, :string, limit: 1024)
  end
end
