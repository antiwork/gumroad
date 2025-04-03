# frozen_string_literal: true

class AddStateAndFailedVerificationAttemptsCountToCustomDomains < ActiveRecord::Migration[6.1]
  def change
    change_table :custom_domains, bulk: true do |t|
      t.string :state, null: false, default: "unverified"
      t.integer :failed_verification_attempts_count, null: false, default: 0
    end
  end
end
