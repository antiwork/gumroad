# frozen_string_literal: true

class AddFlagsToWorkflows < ActiveRecord::Migration[4.2]
  def change
    add_column :workflows, :flags, :bigint, default: 0, null: false
  end
end
