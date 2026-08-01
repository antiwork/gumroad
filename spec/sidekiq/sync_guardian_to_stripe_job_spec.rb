# frozen_string_literal: true

require "spec_helper"

describe SyncGuardianToStripeJob do
  let(:seller) { create(:user) }
  let(:stripe_account) { double(id: "acct_123") }

  before do
    create(:user_compliance_info, user: seller, birthday: 15.years.ago.to_date)
    create(:guardian, user: seller)
  end

  it "sends the guardian to the seller's Stripe account" do
    # Explicit merchant id: the factory's process-local sequence collides with the checked-in
    # gumroad_stripe fixture row, and the uniqueness validation fails setup before the job runs.
    merchant_account = create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_spec_guardian_sync")
    expect(Stripe::Account).to receive(:retrieve)
      .with(merchant_account.charge_processor_merchant_id).and_return(stripe_account)
    expect(StripeGuardianManager).to receive(:sync).with(seller, stripe_account, passphrase: anything)

    described_class.new.perform(seller.id)
  end

  # Nothing of ours to add a Person to, and Stripe verifies that account under its own agreement
  # with the seller — the same exemption the payout gate and the settings page apply.
  it "does nothing for a seller paid through their own connected Stripe account" do
    create(:merchant_account_stripe_connect, user: seller, country: "US")
    seller.update!(check_merchant_account_is_linked: true)
    expect(StripeGuardianManager).not_to receive(:sync)

    described_class.new.perform(seller.id)
  end

  # Stripe cannot pay a Brazilian connected account out, so the payout gate does not exempt it and
  # the settings page asks this seller for a guardian. Exempting here on the broader
  # has_stripe_account_connected? accepted the guardian, told the seller they were done, and never
  # sent it — leaving the requirement that stopped their payouts unmet with nothing left to do.
  it "still syncs for a minor whose connected Stripe account is Brazilian" do
    create(:merchant_account_stripe_connect, user: seller, country: "BR")
    seller.update!(check_merchant_account_is_linked: true)
    merchant_account = create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_spec_guardian_sync_br")

    expect(Stripe::Account).to receive(:retrieve)
      .with(merchant_account.charge_processor_merchant_id).and_return(stripe_account)
    expect(StripeGuardianManager).to receive(:sync).with(seller, stripe_account, passphrase: anything)

    described_class.new.perform(seller.id)
  end

  # A seller can complete the guardian form before their payout account exists. Raising here would
  # retry against an account that is not coming; the account's own creation syncs the guardian.
  it "does nothing when the seller has no Stripe account yet" do
    expect(StripeGuardianManager).not_to receive(:sync)

    described_class.new.perform(seller.id)
  end
end
