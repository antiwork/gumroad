# frozen_string_literal: true

class AddIndianCardMandateRestartNoticeOwedToSubscriptions < ActiveRecord::Migration[7.1]
  def change
    change_table :subscriptions, bulk: true do |t|
      t.boolean :indian_card_mandate_restart_notice_owed, default: false, null: false
      t.datetime :indian_card_mandate_restart_notice_recorded_at
    end
  end
end
