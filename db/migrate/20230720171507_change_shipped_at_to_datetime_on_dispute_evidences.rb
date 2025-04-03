# frozen_string_literal: true

class ChangeShippedAtToDatetimeOnDisputeEvidences < ActiveRecord::Migration[7.0]
  def up
    execute "UPDATE `dispute_evidences` SET `dispute_evidences`.`shipped_at` = NULL;"
    change_column :dispute_evidences, :shipped_at, :datetime
  end

  def down
    change_column :dispute_evidences, :shipped_at, :string
  end
end
