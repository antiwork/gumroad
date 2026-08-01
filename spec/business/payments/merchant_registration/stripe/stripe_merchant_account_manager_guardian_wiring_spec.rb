# frozen_string_literal: true

require "spec_helper"

# Proves the guardian sync is actually wired into the two places the Stripe account is written.
# The StripeGuardianManager unit spec covers what gets sent; this covers that anything gets sent at
# all — without it, deleting both call sites leaves the whole suite green.
#
# Deliberately not :vcr. These assert the seam, not Stripe's responses, so the whole Stripe surface
# is stubbed rather than recorded.
describe StripeMerchantAccountManager, "guardian sync wiring" do
  let(:user) { create(:user) }
  let(:passphrase) { GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD") }
  let(:stripe_account) { Stripe::StripeObject.construct_from(id: "acct_wiring_test", metadata: {}) }

  before do
    allow(StripeGuardianManager).to receive(:sync)
  end

  describe "#create_account" do
    let!(:user_compliance_info) { create(:user_compliance_info, user:, birthday: 15.years.ago.to_date) }
    let!(:tos_agreement) { create(:tos_agreement, user:) }

    before do
      allow(Stripe::Account).to receive(:create).and_return(stripe_account)
      allow(Stripe::Account).to receive(:list_persons)
        .and_return(Stripe::StripeObject.construct_from(data: []))
    end

    it "syncs the guardian" do
      described_class.create_account(user, passphrase:)

      expect(StripeGuardianManager).to have_received(:sync).with(user, stripe_account, passphrase:)
    end

    # The account and the merchant record are already live by this point, so a failing sync must not
    # abort creation and leave a merchant account that was never marked alive.
    it "does not fail account creation when the sync raises" do
      allow(StripeGuardianManager).to receive(:sync).and_raise(Stripe::APIError.new("stripe is down"))

      expect { described_class.create_account(user, passphrase:) }.not_to raise_error
      expect(user.reload.stripe_account).to be_present
    end

    # Not just Stripe errors: the sync writes locally too, and a deadlock there would otherwise
    # escape a Stripe-only rescue.
    it "does not fail account creation when the sync raises a non-Stripe error" do
      allow(StripeGuardianManager).to receive(:sync).and_raise(ActiveRecord::Deadlocked.new("deadlock"))

      expect { described_class.create_account(user, passphrase:) }.not_to raise_error
      expect(user.reload.stripe_account).to be_present
    end
  end

  describe "#update_account" do
    let!(:merchant_account) do
      create(:merchant_account, user:, charge_processor_merchant_id: "acct_wiring_test")
    end
    let!(:user_compliance_info) { create(:user_compliance_info, user:, birthday: 15.years.ago.to_date) }
    let!(:tos_agreement) { create(:tos_agreement, user:) }

    before do
      allow(Stripe::Account).to receive(:retrieve).and_return(update_stripe_account)
      allow(Stripe::Account).to receive(:update).and_return(update_stripe_account)
      allow(Stripe::Account).to receive(:list_persons)
        .and_return(Stripe::StripeObject.construct_from(data: []))
    end

    # update_account reads more off the account than create_account does.
    let(:update_stripe_account) do
      Stripe::StripeObject.construct_from(
        id: "acct_wiring_test",
        metadata: { "user_compliance_info_id" => user_compliance_info.external_id },
        capabilities: {},
        country: "US",
        requirements: { currently_due: [], eventually_due: [], past_due: [] },
        future_requirements: { currently_due: [], past_due: [] }
      )
    end

    # The seller's own country and date of birth decide whether a guardian is required at all, so
    # the sync runs on every update rather than only when the guardian itself changed.
    it "syncs the guardian" do
      described_class.update_account(user, passphrase:)

      expect(StripeGuardianManager).to have_received(:sync).with(user, update_stripe_account, passphrase:)
    end

    it "does not fail the seller's own save when the sync raises" do
      allow(StripeGuardianManager).to receive(:sync).and_raise(Stripe::APIError.new("stripe is down"))

      expect { described_class.update_account(user, passphrase:) }.not_to raise_error
    end
  end
end
