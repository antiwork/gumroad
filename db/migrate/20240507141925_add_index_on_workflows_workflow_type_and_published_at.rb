# frozen_string_literal: true

class AddIndexOnWorkflowsWorkflowTypeAndPublishedAt < ActiveRecord::Migration[7.1]
  def change
    add_index :workflows, [:workflow_type, :published_at]
  end
end
