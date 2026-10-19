# frozen_string_literal: true

require "spec_helper"

describe StripePayoutRailSetups::Activate do
  include_context "with Stripe API stubs"

  let(:seller) { create(:user, payment_address: "seller-payouts@example.com", invalidated_paypal_payout_address: "older-paypal@example.com") }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:team_member) { create(:user, is_team_member: true) }
  let(:consent_reference) { "support-thread-synthetic-1" }
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
    StripePayoutRailSetups::Provision.new(staged).process
    staged.reload
  end

  before do
    create(:user_compliance_info_business, user: seller, country: "French Polynesia")
    create(:tos_agreement, user: seller)
    Feature.activate_user(:merchant_migration, seller)
    Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
    expect(setup).to be_prepared
  end

  # What provisioning sent to Stripe, as the shared stub recorded it; read before any example restubs retrieve.
  let!(:provisioned_metadata) { Stripe::Account.retrieve(setup.merchant_account.charge_processor_merchant_id)["metadata"].to_h.stringify_keys }

  # Unit control for the provider readiness read, shaped like Stripe's account and bank_account objects.
  def stub_provider_account(payouts_enabled: true, charges_enabled: true, disabled_reason: nil, country: "US", external_account: {}, metadata: provisioned_metadata, currently_due: [], past_due: [], during_read: nil)
    linked = { id: setup.bank_account.stripe_bank_account_id, object: "bank_account", status: "new", currency: "usd", country: "US" }.merge(external_account)
    allow(Stripe::Account).to receive(:retrieve).with(setup.merchant_account.charge_processor_merchant_id) do
      during_read&.call
      Stripe::Account.construct_from(
        id: setup.merchant_account.charge_processor_merchant_id, country:, payouts_enabled:, charges_enabled:, metadata:,
        requirements: { disabled_reason:, currently_due:, past_due: },
        external_accounts: { object: "list", data: [linked] }
      )
    end
  end

  def activate(activated_by: team_member, consent: consent_reference)
    described_class.new(setup:, activated_by:, consent_reference: consent).process
  end

  def expect_nothing_switched_on
    seller.reload
    expect(setup.reload).to be_prepared
    expect(setup.bank_account.reload).to be_deleted
    expect(setup.merchant_account.reload.charge_processor_alive?).to be(false)
    expect(seller.stripe_account).to be_nil
    expect(seller.active_bank_account).to be_nil
    expect(seller.payment_address).to eq("seller-payouts@example.com")
    expect(seller.current_payout_processor).to eq(PayoutProcessorType::PAYPAL)
    expect(PaypalPayoutProcessor.is_user_payable(seller, 100_00)).to be(true)
  end

  it "switches the prepared rail on with the seller's recorded consent" do
    stub_provider_account
    old_bank_account = create(:ach_account, user: seller)

    result = activate

    expect(result.success).to be(true)
    seller.reload
    setup.reload
    expect(setup.state).to eq(StripePayoutRailSetup::ACTIVATED)
    expect(setup.activated_by).to eq(team_member)
    expect(setup.consent_reference).to eq(consent_reference)
    expect(setup.activated_at).to be_present
    expect(old_bank_account.reload).to be_deleted
    expect(seller.active_bank_account).to eq(setup.bank_account)
    expect(seller.stripe_account).to eq(setup.merchant_account)
    expect(seller.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq(setup.merchant_account)
    expect(StripePayoutProcessor.destination_merchant_account(seller, [])).to eq(setup.merchant_account)
    expect(seller.payment_address).to eq("")
    expect(seller.invalidated_paypal_payout_address).to be_nil
    expect(seller.current_payout_processor).to eq(PayoutProcessorType::STRIPE)
    expect(PaypalPayoutProcessor.is_user_payable(seller, 100_00)).to be(false)
    expect(seller.has_stripe_account_connected?).to be(false)
    expect(seller.stripe_connect_account).to eq(connect_account)
  end

  describe "the suspended-fingerprint fraud check" do
    let(:suspended_seller) { create(:user, user_risk_state: "suspended_for_fraud") }

    it "runs on the activated bank once it is the payout destination, and flags a match" do
      fingerprint = setup.bank_account.reload.stripe_fingerprint
      expect(fingerprint).to be_present
      create(:ach_account, user: suspended_seller, stripe_fingerprint: fingerprint)
      # The check queued while preparing ran before the candidate was alive, so it could not see it.
      CheckPaymentAddressWorker.drain
      expect(seller.reload.flagged?).to be(false)
      stub_provider_account

      expect(activate.success).to be(true)

      expect(CheckPaymentAddressWorker.jobs.map { _1["args"] }).to eq([[seller.id]])
      CheckPaymentAddressWorker.drain
      expect(seller.reload.flagged?).to be(true)
    end

    it "does not flag an activated bank no suspended seller uses" do
      create(:ach_account, user: suspended_seller, stripe_fingerprint: "fp_synthetic_unrelated")
      CheckPaymentAddressWorker.drain
      stub_provider_account

      expect(activate.success).to be(true)
      CheckPaymentAddressWorker.drain

      expect(seller.reload.flagged?).to be(false)
    end

    it "is not queued by a refused activation, before or under the seller lock" do
      CheckPaymentAddressWorker.drain
      stub_provider_account(payouts_enabled: false)
      expect(activate.success).to be(false)

      stub_provider_account(during_read: -> { User.find(seller.id).update!(payment_address: "newer-paypal@example.com") })
      expect(activate.error).to eq(:rail_setup_changed)

      expect(CheckPaymentAddressWorker.jobs).to be_empty
    end
  end

  {
    "the rollout gate is closed" => -> { Feature.deactivate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller) },
    "Connect routes card sales" => -> { seller.update!(check_merchant_account_is_linked: true) },
    "a payout is in flight" => -> { create(:payment, user: seller, state: Payment::PROCESSING) },
    "a PayPal payout is unclaimed" => -> { create(:payment, user: seller, state: Payment::UNCLAIMED) },
    "a managed account is already live" => -> { create(:merchant_account, user: seller, country: "US") },
    "the stored Connect row is gone" => -> { connect_account.delete_charge_processor_account! },
  }.each do |description, arrange|
    it "refuses when #{description}" do
      stub_provider_account
      instance_exec(&arrange)

      expect(activate.success).to be(false)
      expect(setup.reload).to be_prepared
      expect(setup.bank_account.reload).to be_deleted
      expect(setup.merchant_account.reload.charge_processor_alive?).to be(false)
      expect(seller.reload.payment_address).to eq("seller-payouts@example.com")
    end
  end

  it "refuses an actor who is not a team member, and a missing consent reference" do
    stub_provider_account

    expect(activate(activated_by: seller).error).to eq(:not_authorized)
    expect(activate(activated_by: nil).error).to eq(:not_authorized)
    expect(activate(consent: " ").error).to eq(:consent_missing)
    expect_nothing_switched_on
  end

  it "refuses while Stripe has not enabled payouts, has restricted or moved the account" do
    stub_provider_account(payouts_enabled: false)
    expect(activate.error).to eq(:stripe_account_not_ready)

    stub_provider_account(disabled_reason: "requirements.past_due")
    expect(activate.error).to eq(:stripe_account_not_ready)

    stub_provider_account(country: "CA")
    expect(activate.error).to eq(:stripe_account_not_ready)
    expect_nothing_switched_on
  end

  {
    "is no longer attached" => { id: "ba_mock_other" },
    "failed verification" => { status: "verification_failed" },
    "errored on a payout" => { status: "errored" },
    "was deleted" => { deleted: true },
    "is in another currency" => { currency: "eur" },
    "is in another country" => { country: "CA" },
    "is not a bank account" => { object: "card" },
  }.each do |description, external_account|
    it "refuses when the linked bank account #{description}" do
      stub_provider_account(external_account:)

      expect(activate.error).to eq(:payout_destination_not_usable)
      expect_nothing_switched_on
    end
  end

  it "accepts a linked bank account Stripe has validated or verified" do
    stub_provider_account(external_account: { status: "verified" })

    expect(activate.success).to be(true)
  end

  it "refuses once the routing gate makes the stored Connect row the card route" do
    stub_provider_account
    Feature.activate_user(User::FeatureStatus::LEGAL_ENTITY_COUNTRY_ROUTING_FEATURE, seller)

    expect(activate.error).to eq(:connect_route_active)
    expect(setup.reload).to be_prepared
  end

  it "refuses a setup whose provider account no longer matches the legal entity" do
    stub_provider_account
    setup.merchant_account.update!(country: "CA")

    expect(activate.error).to eq(:incompatible_bank_rail)
    expect_nothing_switched_on
  end

  it "refuses once the seller's compliance details change after the account was prepared" do
    expect(provisioned_metadata["user_compliance_info_id"]).to eq(seller.alive_user_compliance_info.external_id)
    provisioned_revision = seller.alive_user_compliance_info.external_id
    seller.alive_user_compliance_info.dup_and_save! { |info| info.business_name = "Renamed After Preparation, LLC" }
    stub_provider_account

    result = activate
    expect(result.error).to eq(:compliance_changed_since_preparation)
    expect(result.details).to eq(synced_compliance_revision: provisioned_revision, current_compliance_revision: seller.reload.alive_user_compliance_info.external_id)
    expect_nothing_switched_on
  end

  it "names what Stripe still needs when the account is not ready" do
    stub_provider_account(payouts_enabled: false, disabled_reason: "requirements.past_due",
                          currently_due: ["individual.verification.document"], past_due: ["individual.id_number"])

    result = activate

    expect(result.error).to eq(:stripe_account_not_ready)
    expect(result.details).to eq(
      payouts_enabled: false, charges_enabled: true, disabled_reason: "requirements.past_due",
      currently_due: ["individual.verification.document"], past_due: ["individual.id_number"]
    )
    expect_nothing_switched_on
  end

  it "refuses when the account does not name the compliance revision it was created from" do
    stub_provider_account(metadata: provisioned_metadata.except("user_compliance_info_id"))

    expect(activate.error).to eq(:compliance_changed_since_preparation)
    expect_nothing_switched_on
  end

  it "refuses a setup that is not prepared" do
    stub_provider_account
    setup.update!(state: StripePayoutRailSetup::PENDING)

    expect(activate.error).to eq(:rail_setup_not_prepared)
  end

  it "re-checks the setup under the seller lock after the provider read" do
    stub_provider_account(during_read: -> { setup.bank_account.update!(account_holder_full_name: "Changed Concurrently") })

    expect(activate.error).to eq(:rail_setup_changed)
    expect_nothing_switched_on
  end

  it "does not overwrite a PayPal address the seller saves during the provider read" do
    stub_provider_account(during_read: -> { User.find(seller.id).update!(payment_address: "newer-paypal@example.com") })

    expect(activate.error).to eq(:rail_setup_changed)
    seller.reload
    expect(seller.payment_address).to eq("newer-paypal@example.com")
    expect(seller.stripe_account).to be_nil
    expect(setup.reload).to be_prepared
  end

  it "does not activate over a payout preference or pause saved during the provider read" do
    stub_provider_account(during_read: -> { User.find(seller.id).update!(payout_frequency: User::PayoutSchedule::MONTHLY) })
    expect(activate.error).to eq(:rail_setup_changed)

    stub_provider_account(during_read: -> { User.find(seller.id).update!(payouts_paused_by_user: true) })
    expect(activate.error).to eq(:rail_setup_changed)
    expect(setup.reload).to be_prepared
    expect(seller.reload.stripe_account).to be_nil
  end

  it "does not activate across a compliance revision or a new bank row saved during the provider read" do
    stub_provider_account(during_read: -> { seller.alive_user_compliance_info.dup_and_save! { |info| info.business_name = "Renamed, LLC" } })
    expect(activate.error).to eq(:rail_setup_changed)

    stub_provider_account(during_read: -> { create(:ach_account, user: seller) })
    expect(activate.error).to eq(:rail_setup_changed)
    expect(setup.reload).to be_prepared
  end

  describe "a prepared debit card" do
    # Built from factories rather than provisioned, so this names the revision a provisioning would have.
    let!(:provisioned_metadata) { { "user_compliance_info_id" => seller.alive_user_compliance_info.external_id } }

    let(:setup) do
      card = create(:card_bank_account, user: seller, credit_card: create(:us_debit_stripe_credit_card), deleted_at: Time.current)
      card.update_columns(stripe_bank_account_id: "card_mock_linked", stripe_connect_account_id: "acct_synthetic_card_rail")
      create(:stripe_payout_rail_setup, :prepared, user: seller, bank_account: card,
                                                   merchant_account: create(:merchant_account, user: seller, charge_processor_alive_at: nil, country: "US", charge_processor_merchant_id: "acct_synthetic_card_rail"))
    end

    it "activates once Stripe offers standard payouts to the linked card" do
      stub_provider_account(external_account: { object: "card", status: nil, available_payout_methods: %w[standard instant] })

      expect(activate.success).to be(true)
      expect(seller.reload.active_bank_account).to eq(setup.bank_account)
      expect(seller.stripe_account).to eq(setup.merchant_account)
    end

    it "refuses a linked card without standard payouts" do
      stub_provider_account(external_account: { object: "card", status: nil, available_payout_methods: [] })

      expect(activate.error).to eq(:payout_destination_not_usable)
      expect(seller.reload.stripe_account).to be_nil
    end
  end
end
