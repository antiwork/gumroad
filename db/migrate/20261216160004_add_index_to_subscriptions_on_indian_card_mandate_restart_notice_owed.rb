# frozen_string_literal: true

class AddIndexToSubscriptionsOnIndianCardMandateRestartNoticeOwed < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_subscriptions_on_indian_mandate_notice_owed_recorded_at"
  COLUMNS = [:indian_card_mandate_restart_notice_owed, :indian_card_mandate_restart_notice_recorded_at].freeze

  # Selective on `owed = true` by design: only an owed notice sets it, and the sweep ranges on `recorded_at` within
  # that prefix to split notices still worth redriving from those past retention.
  def up
    return if index_exists?(:subscriptions, COLUMNS, name: INDEX_NAME)

    add_index :subscriptions, COLUMNS, name: INDEX_NAME
  end

  def down
    return unless index_exists?(:subscriptions, COLUMNS, name: INDEX_NAME)

    remove_index :subscriptions, name: INDEX_NAME
  end
end
