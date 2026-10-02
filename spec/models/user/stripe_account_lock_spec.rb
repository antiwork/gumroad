# frozen_string_literal: true

require "spec_helper"

describe User, "#stripe_account with lock: true" do
  it "locks the owner's Stripe accounts while returning the managed one" do
    creator = create(:user)
    stripe_account = create(:merchant_account, user: creator, charge_processor_merchant_id: "acct_managed_lock")
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }

    expect(creator.stripe_account(lock: true)).to eq stripe_account
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(statements).to include(a_string_matching(/FROM `merchant_accounts`.*FOR UPDATE/))
  end
end
