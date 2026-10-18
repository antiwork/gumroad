# frozen_string_literal: true

require "spec_helper"

# A minor seller's guardian is synced to the prepared account once, while it is provisioned; nothing
# syncs it again before the account is live. Activation must match the guardian Stripe was given.
describe StripePayoutRailSetups::Activate, "for a seller with a legal guardian" do
  include_context "with Stripe API stubs"

  let(:seller) { create(:user, payment_address: "seller-payouts@example.com") }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:team_member) { create(:user, is_team_member: true) }
  let(:guardian) { create(:guardian, user: seller) }
  let(:attach_guardian_before_preparation) { true }
  let(:guardian_sync_fails) { false }
  let(:guardian_changes_during_sync) { false }
  let(:setup) do
    params = ActionController::Parameters.new(
      bank_account: {
        type: AchAccount.name,
        account_number: "000123456789",
        account_number_confirmation: "000123456789",
        routing_number: "110000000",
        account_holder_full_name: "Synthetic Holder",
      }
    )
    staged = StripePayoutRailSetups::Stage.new(seller:, params:).process.setup
    expect(StripePayoutRailSetups::Provision.new(staged).process.success).to be(true)
    staged.reload
  end

  before do
    info = create(:user_compliance_info, user: seller, birthday: 15.years.ago.to_date)
    info.update!(guardian_id: guardian.id) if attach_guardian_before_preparation
    expect(seller.alive_user_compliance_info.requires_legal_guardian?).to be(true)
    create(:tos_agreement, user: seller)
    Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
    # SDK double: the account holds no Person yet, so the guardian sync creates one.
    allow(Stripe::Account).to receive(:list_persons).and_return(Stripe::StripeObject.construct_from(data: [], has_more: false))
    # SDK double: Stripe gives no verdict on the guardian Person; account creation carries on regardless.
    allow(Stripe::Account).to receive(:create_person).and_raise(Stripe::APIConnectionError.new("Connection reset")) if guardian_sync_fails
    if guardian_changes_during_sync
      # SDK double: the guardian is edited while Stripe is still creating the Person from the old details.
      allow(Stripe::Account).to receive(:create_person) do |_account_id, _params|
        Guardian.find(guardian.id).update!(first_name: "Edited During Sync")
        Stripe::StripeObject.construct_from(id: "person_mock_during_sync", object: "person")
      end
    end
    expect(setup).to be_prepared
  end

  # SDK double for the provider readiness read.
  def stub_provider_account(during_read: nil)
    account_id = setup.merchant_account.charge_processor_merchant_id
    compliance_revision = seller.alive_user_compliance_info.external_id
    allow(Stripe::Account).to receive(:retrieve).with(account_id) do
      during_read&.call
      Stripe::Account.construct_from(
        id: account_id, country: "US", payouts_enabled: true, metadata: { user_compliance_info_id: compliance_revision },
        requirements: { disabled_reason: nil, currently_due: [], past_due: [] },
        external_accounts: { object: "list", data: [{ id: setup.bank_account.stripe_bank_account_id, object: "bank_account", status: "new", currency: "usd", country: "US" }] }
      )
    end
  end

  def activate
    described_class.new(setup:, activated_by: team_member, consent_reference: "support-thread-synthetic-5").process
  end

  def expect_nothing_switched_on
    expect(setup.reload).to be_prepared
    expect(setup.merchant_account.reload.charge_processor_alive?).to be(false)
    expect(seller.reload.stripe_account).to be_nil
    expect(seller.payment_address).to eq("seller-payouts@example.com")
  end

  it "activates when the guardian is the one Stripe was given" do
    expect(Stripe::Account).to have_received(:create_person).at_least(:once)
    stub_provider_account

    expect(activate.success).to be(true)
    expect(seller.reload.stripe_account).to eq(setup.merchant_account)
  end

  it "refuses once the guardian's details change after preparation" do
    guardian.update!(first_name: "Renamed")
    stub_provider_account

    expect(activate.error).to eq(:guardian_changed_since_preparation)
    expect_nothing_switched_on
  end

  it "refuses when the guardian changes during the provider read" do
    stub_provider_account(during_read: -> { Guardian.find(guardian.id).update!(last_name: "Changed Concurrently") })

    expect(activate.error).to eq(:rail_setup_changed)
    expect_nothing_switched_on
  end

  context "when the guardian sync did not complete while the account was prepared" do
    let(:guardian_sync_fails) { true }

    it "refuses, because Stripe may not hold the guardian" do
      stub_provider_account

      expect(activate.error).to eq(:guardian_changed_since_preparation)
      expect_nothing_switched_on
    end
  end

  context "when the guardian changes while the provisioning sync is writing Stripe" do
    let(:guardian_changes_during_sync) { true }

    it "refuses, because Stripe was given the details from before the edit" do
      stub_provider_account

      expect(activate.error).to eq(:guardian_changed_since_preparation)
      expect_nothing_switched_on
    end
  end

  context "when the guardian is attached to the same compliance revision after preparation" do
    let(:attach_guardian_before_preparation) { false }

    it "refuses, because Stripe was never given that guardian" do
      revision = seller.alive_user_compliance_info
      revision.update!(guardian_id: guardian.id)
      expect(seller.reload.alive_user_compliance_info.external_id).to eq(revision.external_id)
      stub_provider_account

      expect(activate.error).to eq(:guardian_changed_since_preparation)
      expect_nothing_switched_on
    end
  end
end
