# frozen_string_literal: true

require "spec_helper"

describe ZenginAccount do
  it "loads legacy rows with type ZenginAccount via single-table inheritance" do
    # Zengin payouts are retired, but old bank_accounts rows still carry this
    # STI type. Simulate one and make sure ActiveRecord can instantiate it
    # (this raised ActiveRecord::SubclassNotFound when the class was removed).
    account = create(:ach_account)
    account.update_column(:type, "ZenginAccount")

    record = BankAccount.find(account.id)
    expect(record).to be_a(ZenginAccount)
    expect(record.bank_account_type).to eq("ZENGIN")
  end
end
