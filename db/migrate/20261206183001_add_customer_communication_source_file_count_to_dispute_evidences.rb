# frozen_string_literal: true

class AddCustomerCommunicationSourceFileCountToDisputeEvidences < ActiveRecord::Migration[7.1]
  def up
    add_column :dispute_evidences, :customer_communication_source_file_count, :integer, null: false, default: 0

    # Backfill existing rows: the pre-fix merge logic never tracked how many source files went
    # into a saved attachment, so 1 is the only defensible floor for a row that has one today —
    # it may undercount a merge that already happened, but it can't overcount (the column
    # controls how many MORE files a future revision may add, so undercounting only makes an
    # already-existing multi-file merge count as fewer files than it truly holds, not a hole
    # that lets the limit be bypassed further).
    execute <<~SQL.squish
      UPDATE dispute_evidences
      INNER JOIN active_storage_attachments
        ON active_storage_attachments.record_type = 'DisputeEvidence'
        AND active_storage_attachments.record_id = dispute_evidences.id
        AND active_storage_attachments.name = 'customer_communication_file'
      SET dispute_evidences.customer_communication_source_file_count = 1
    SQL
  end

  def down
    remove_column :dispute_evidences, :customer_communication_source_file_count
  end
end
