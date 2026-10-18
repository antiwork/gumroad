# frozen_string_literal: true

require "spec_helper"

# A Danish seller with a German IBAN is paid out cross-border in EUR: bank_account_hash sends Stripe
# the IBAN's country and EUR, not the bank row's local DK/DKK.
describe StripePayoutRailSetups::Activate, "for a cross-border SEPA bank account" do
  let(:seller) { create(:user, payment_address: "seller-payouts@example.com") }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:team_member) { create(:user, is_team_member: true) }
  let(:candidate) do
    create(:denmark_bank_account, user: seller, account_number: "DE89370400440532013000", deleted_at: Time.current).tap do |bank_account|
      bank_account.update_columns(stripe_bank_account_id: "ba_synthetic_sepa", stripe_connect_account_id: "acct_synthetic_sepa_rail")
    end
  end
  let(:setup) do
    create(:stripe_payout_rail_setup, :prepared, user: seller, bank_account: candidate,
                                                 merchant_account: create(:merchant_account, user: seller, charge_processor_alive_at: nil, country: "DK", currency: "dkk",
                                                                                             charge_processor_merchant_id: "acct_synthetic_sepa_rail"))
  end

  before do
    create(:user_compliance_info, user: seller, country: "Denmark")
    Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
    expect([candidate.stripe_external_account_country, candidate.stripe_external_account_currency]).to eq(["DE", "eur"])
    expect([candidate.country, candidate.currency]).to eq(["DK", "dkk"])
  end

  # SDK double for the provider readiness read; it says what Stripe holds, not that Stripe accepts it.
  def stub_provider_account(external_account)
    linked = { id: "ba_synthetic_sepa", object: "bank_account", status: "new" }.merge(external_account)
    allow(Stripe::Account).to receive(:retrieve).with("acct_synthetic_sepa_rail") do
      Stripe::Account.construct_from(
        id: "acct_synthetic_sepa_rail", country: "DK", payouts_enabled: true,
        metadata: { user_compliance_info_id: seller.alive_user_compliance_info.external_id },
        requirements: { disabled_reason: nil, currently_due: [], past_due: [] },
        external_accounts: { object: "list", data: [linked] }
      )
    end
  end

  def activate
    described_class.new(setup:, activated_by: team_member, consent_reference: "support-thread-synthetic-4").process
  end

  it "activates when Stripe holds the IBAN in its own country and EUR" do
    stub_provider_account(country: "DE", currency: "eur")

    expect(activate.success).to be(true)
    expect(seller.reload.stripe_account).to eq(setup.merchant_account)
    expect(seller.active_bank_account).to eq(candidate)
  end

  {
    "the seller's local country and currency" => { country: "DK", currency: "dkk" },
    "another country" => { country: "FR", currency: "eur" },
    "another currency" => { country: "DE", currency: "dkk" },
    "a failed verification" => { country: "DE", currency: "eur", status: "verification_failed" },
  }.each do |description, external_account|
    it "refuses when Stripe's external account has #{description}" do
      stub_provider_account(external_account)

      expect(activate.error).to eq(:payout_destination_not_usable)
      expect(setup.reload).to be_prepared
      expect(seller.reload.stripe_account).to be_nil
      expect(seller.payment_address).to eq("seller-payouts@example.com")
    end
  end
end
