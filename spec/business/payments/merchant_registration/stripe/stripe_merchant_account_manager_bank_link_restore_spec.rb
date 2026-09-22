# frozen_string_literal: true

require "spec_helper"

# gumroad-private#2882: a "Change account" save set the Stripe account's metadata.bank_account_id
# but never reached save_stripe_bank_account_info, so the active local bank row kept
# stripe_bank_account_id NULL. update_bank_account reported that as :noop_metadata_match, which
# RetryStripeRejectedPayoutSetupForSellerJob reads as success — the retry loop stopped, no failure
# note was recorded, and every payout for the seller was skipped from then on.
describe StripeMerchantAccountManager do
  include_context "with Stripe API stubs"

  let(:passphrase) { "1234" }
  let(:user) { create(:user, payment_address: nil) }
  let!(:user_compliance_info) { create(:user_compliance_info, user:) }
  let!(:merchant_account) { create(:merchant_account, user:) }
  let!(:bank_account) { create(:ach_account, user:) }

  let(:merchant_id) { user.stripe_account.charge_processor_merchant_id }

  def stripe_bank_account_payload(overrides = {})
    Stripe::StripeObject.construct_from(
      {
        id: "ba_recovered_from_stripe",
        object: "bank_account",
        last4: bank_account.account_number_last_four,
        routing_number: bank_account.stripe_external_account_routing_number,
        currency: bank_account.stripe_external_account_currency,
        account_holder_name: bank_account.account_holder_full_name,
        fingerprint: "fp_recovered_from_stripe",
      }.merge(overrides)
    )
  end

  def stub_stripe_account_with(external_accounts)
    allow(Stripe::Account).to receive(:retrieve).with(merchant_id).and_return(
      Stripe::Account.construct_from(
        id: merchant_id,
        metadata: { "bank_account_id" => bank_account.external_id },
        external_accounts: Stripe::ListObject.construct_from(
          object: "list",
          url: "/v1/accounts/#{merchant_id}/external_accounts",
          has_more: false,
          data: external_accounts
        )
      )
    )
  end

  # The state the 2026-08-27 save left: the row is active, Stripe has the account, nothing local
  # points at it.
  def unlink_bank_row!
    bank_account.update_columns(stripe_bank_account_id: nil, stripe_connect_account_id: nil, stripe_fingerprint: nil, state: "unverified")
    bank_account.reload
  end

  before do
    allow(CheckPaymentAddressWorker).to receive(:perform_async)
  end

  describe "a bank row Stripe already holds but has never been linked locally" do
    before { unlink_bank_row! }

    it "links the external account Stripe already holds and reports the sync as done" do
      stub_stripe_account_with([stripe_bank_account_payload])

      expect(described_class.update_bank_account(user, passphrase:)).to eq(:synced)

      bank_account.reload
      expect(bank_account.stripe_bank_account_id).to eq("ba_recovered_from_stripe")
      expect(bank_account.stripe_fingerprint).to eq("fp_recovered_from_stripe")
      expect(bank_account.stripe_connect_account_id).to eq(merchant_id)
    end

    it "makes the seller payable again" do
      stub_stripe_account_with([stripe_bank_account_payload])
      expect(StripePayoutProcessor.has_valid_payout_info?(user)).to be(false)

      described_class.update_bank_account(user, passphrase:)

      expect(StripePayoutProcessor.has_valid_payout_info?(user.reload)).to be(true)
    end

    it "does not link an external account that cannot be shown to be this row" do
      stub_stripe_account_with([stripe_bank_account_payload(last4: "9999")])

      expect(described_class.update_bank_account(user, passphrase:)).to eq(:noop_metadata_match)
      expect(bank_account.reload.stripe_bank_account_id).to be_nil
    end

    it "does not link an external account whose routing number differs from the row's" do
      stub_stripe_account_with([stripe_bank_account_payload(routing_number: "021000021")])

      expect(described_class.update_bank_account(user, passphrase:)).to eq(:noop_metadata_match)
      expect(bank_account.reload.stripe_bank_account_id).to be_nil
    end

    it "refuses to guess when two external accounts look like this row" do
      stub_stripe_account_with([
                                 stripe_bank_account_payload,
                                 stripe_bank_account_payload(id: "ba_second_match")
                               ])

      expect(described_class.update_bank_account(user, passphrase:)).to eq(:noop_metadata_match)
      expect(bank_account.reload.stripe_bank_account_id).to be_nil
    end

    it "stays a no-op when Stripe holds no external account at all" do
      stub_stripe_account_with([])

      expect(described_class.update_bank_account(user, passphrase:)).to eq(:noop_metadata_match)
      expect(bank_account.reload.stripe_bank_account_id).to be_nil
    end
  end

  describe "a bank row that is already linked" do
    before do
      bank_account.update_columns(
        stripe_bank_account_id: "ba_already_linked",
        stripe_connect_account_id: merchant_id,
        stripe_fingerprint: "fp_already_linked"
      )
      bank_account.reload
    end

    it "keeps reporting the metadata match without rewriting the link" do
      stub_stripe_account_with([stripe_bank_account_payload])
      expect(Stripe::Account).not_to receive(:update)

      expect(described_class.update_bank_account(user, passphrase:)).to eq(:noop_metadata_match)

      bank_account.reload
      expect(bank_account.stripe_bank_account_id).to eq("ba_already_linked")
      expect(bank_account.stripe_fingerprint).to eq("fp_already_linked")
    end
  end

  # A holder-name mismatch in a sync country still has to reach Account.update.
  it "sends a holder-name change for a name-sync country instead of stopping on the metadata match" do
    user_compliance_info.update_columns(country: "Japan")
    bank_account.update!(account_holder_full_name: "Updated Name")
    stub_stripe_account_with([stripe_bank_account_payload(account_holder_name: "Previous Name")])
    expect(Stripe::Account).to receive(:update).with(
      merchant_id,
      hash_including(bank_account: hash_including(account_holder_name: "Updated Name"))
    ).and_raise(StandardError, "stop here")

    expect { described_class.update_bank_account(user, passphrase:) }.to raise_error(StandardError, "stop here")
  end
end
