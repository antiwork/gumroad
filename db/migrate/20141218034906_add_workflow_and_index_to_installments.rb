# frozen_string_literal: true

class AddWorkflowAndIndexToInstallments < ActiveRecord::Migration
  def change
    add_column :installments, :workflow_id, :integer
    add_index :installments, :workflow_id
  end
end
