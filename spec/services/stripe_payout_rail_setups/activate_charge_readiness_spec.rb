# frozen_string_literal: true

require "spec_helper"

# Activation makes the managed account the seller's card route wherever Stripe takes direct charges in
# its country, so Stripe must have enabled charges there; payout-only countries never take charges.
describe StripePayoutRailSetups::Activate, "charge readiness" do
  include_context "with Stripe API stubs"

  let(:team_member) { create(:user, is_team_member: true) }

  def activate(setup)
    described_class.new(setup:, activated_by: team_member, consent_reference: "support-thread-synthetic-12").process
  end

  # SDK double for the provider readiness read; it says what Stripe reports, not that Stripe accepts it.
  def stub_provider_account(setup, charges_enabled:, country:, external_account:)
    allow(Stripe::Account).to receive(:retrieve).with(setup.merchant_account.charge_processor_merchant_id) do
      Stripe::Account.construct_from(
        id: setup.merchant_account.charge_processor_merchant_id, country:, payouts_enabled: true, charges_enabled:,
        metadata: { user_compliance_info_id: setup.user.alive_user_compliance_info.external_id },
        requirements: { disabled_reason: nil, currently_due: [], past_due: [] },
        external_accounts: { object: "list", data: [{ id: setup.bank_account.stripe_bank_account_id }.merge(external_account)] }
      )
    end
  end

  context "in a country where Stripe takes direct charges" do
    let(:seller) { create(:user, payment_address: "seller-payouts@example.com") }
    let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
    let(:setup) do
      params = ActionController::Parameters.new(
        bank_account: { type: AchAccount.name, account_number: "000123456789", account_number_confirmation: "000123456789", routing_number: "110000000", account_holder_full_name: "Synthetic Holder" }
      )
      staged = StripePayoutRailSetups::Stage.new(seller:, params:).process.setup
      expect(StripePayoutRailSetups::Provision.new(staged).process.success).to be(true)
      staged.reload
    end

    before do
      create(:user_compliance_info, user: seller)
      create(:tos_agreement, user: seller)
      Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
      expect(setup).to be_prepared
      expect(setup.merchant_account.can_accept_charges?).to be(true)
    end

    def stub_ready_bank(charges_enabled:)
      stub_provider_account(setup, charges_enabled:, country: "US", external_account: { object: "bank_account", status: "new", currency: "usd", country: "US" })
    end

    it "refuses while Stripe has payouts but not charges enabled, changing nothing, and activates once charges are enabled" do
      payout_weekday = seller.payout_weekday
      threshold = seller.payout_threshold_cents
      address_checks = CheckPaymentAddressWorker.jobs.size
      stub_ready_bank(charges_enabled: false)

      result = activate(setup)

      expect(result.success).to be(false)
      expect(result.error).to eq(:stripe_account_not_ready)
      expect(result.details).to include(charges_enabled: false, payouts_enabled: true)
      setup.reload
      expect(setup).to be_prepared
      expect(setup.activated_at).to be_nil
      expect(setup.bank_account.reload).to be_deleted
      expect(setup.merchant_account.reload.charge_processor_alive?).to be(false)
      seller.reload
      expect(seller.payment_address).to eq("seller-payouts@example.com")
      expect(seller.stripe_account).to be_nil
      expect(seller.active_bank_account).to be_nil
      expect(seller.current_payout_processor).to eq(PayoutProcessorType::PAYPAL)
      expect(seller.payout_weekday).to eq(payout_weekday)
      expect(seller.payout_threshold_cents).to eq(threshold)
      expect(CheckPaymentAddressWorker.jobs.size).to eq(address_checks)

      stub_ready_bank(charges_enabled: true)

      expect(activate(StripePayoutRailSetup.find(setup.id)).success).to be(true)
      expect(seller.reload.stripe_account).to eq(setup.merchant_account)
      expect(seller.active_bank_account).to eq(setup.bank_account)
    end
  end

  context "in a payout-only country" do
    let(:seller) { create(:user, payment_address: "seller-payouts@example.com") }
    let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
    let(:candidate) do
      create(:korea_bank_account, user: seller, deleted_at: Time.current).tap do |bank_account|
        bank_account.update_columns(stripe_bank_account_id: "ba_synthetic_kr", stripe_connect_account_id: "acct_synthetic_kr_rail")
      end
    end
    let(:setup) do
      create(:stripe_payout_rail_setup, :prepared, user: seller, bank_account: candidate,
                                                   merchant_account: create(:merchant_account, user: seller, charge_processor_alive_at: nil, country: "KR", currency: "krw",
                                                                                               charge_processor_merchant_id: "acct_synthetic_kr_rail"))
    end

    before do
      create(:user_compliance_info_korea, user: seller)
      Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
      expect(setup.merchant_account.can_accept_charges?).to be(false)
    end

    it "activates with charges disabled, because the account never takes card sales" do
      stub_provider_account(setup, charges_enabled: false, country: "KR",
                                   external_account: { object: "bank_account", status: "new", currency: candidate.stripe_external_account_currency, country: candidate.stripe_external_account_country })

      expect(activate(setup).success).to be(true)
      expect(seller.reload.stripe_account).to eq(setup.merchant_account)
      expect(seller.active_bank_account).to eq(candidate)
    end
  end
end
