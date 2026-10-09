# frozen_string_literal: true

class AddOutcomeNotifiedAtToPiracyReports < ActiveRecord::Migration[7.1]
  INDEX_COLUMNS = %i[counter_notice_received_on seller_id].freeze

  # Guarded: a branch database that ran an earlier draft of 20261216150003 already has both.
  def up
    add_column :piracy_reports, :outcome_notified_at, :datetime unless column_exists?(:piracy_reports, :outcome_notified_at)
    return if index_exists?(:piracy_reports, INDEX_COLUMNS)

    # Rolling back 20261216150003 drops the date column, and MySQL shrinks this index to seller_id under the same name.
    name = index_name(:piracy_reports, INDEX_COLUMNS)
    remove_index :piracy_reports, name: name if index_name_exists?(:piracy_reports, name)
    add_index :piracy_reports, INDEX_COLUMNS
  end

  # Leaves both in place: a database that ran that earlier draft records the same 20261216150003 version
  # and still needs them, and nothing tells the two apart. Unused, they are harmless.
  def down; end
end
