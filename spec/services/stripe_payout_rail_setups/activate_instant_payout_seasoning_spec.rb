# frozen_string_literal: true

require "spec_helper"

describe "Instant-payout seasoning of a payout rail setup's account" do
  include_context "with Stripe API stubs"

  let(:seller) { create(:compliant_user, payment_address: "seller-payouts@example.com") }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:team_member) { create(:user, is_team_member: true) }
  let(:seasoning) { User::MIN_ACCOUNT_AGE_FOR_INSTANT_PAYOUTS }

  before do
    create(:user_compliance_info, user: seller)
    create(:tos_agreement, user: seller)
    create(:payment_completed, user: seller)
    Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
    # SDK double for Stripe's view of a prepared account: charges and payouts enabled, the compliance
    # revision provisioning sent, and the linked destination ready for standard and instant payouts.
    allow(Stripe::Account).to receive(:retrieve) do |account_id, *_args|
      setup = StripePayoutRailSetup.joins(:merchant_account).find_by!(merchant_accounts: { charge_processor_merchant_id: account_id })
      destination = if setup.card?
        { id: "card_mock_linked", object: "card", fingerprint: "fp_card_mock", currency: "usd", country: "US", available_payout_methods: %w[standard instant] }
      else
        { id: setup.bank_account.stripe_bank_account_id, object: "bank_account", status: "new", currency: "usd", country: "US" }
      end
      Stripe::Account.construct_from(
        id: account_id, object: "account", country: "US", default_currency: "usd", charges_enabled: true, payouts_enabled: true,
        metadata: { user_compliance_info_id: seller.alive_user_compliance_info.external_id },
        requirements: { disabled_reason: nil, currently_due: [], past_due: [] },
        external_accounts: { object: "list", data: [destination] }
      )
    end
  end

  def prepare(params)
    setup = StripePayoutRailSetups::Stage.new(seller:, params:).process.setup
    expect(StripePayoutRailSetups::Provision.new(setup).process.success).to be(true)
    expect(setup.reload).to be_prepared
    setup
  end

  def prepare_bank(account_number)
    prepare(ActionController::Parameters.new(
              bank_account: { type: AchAccount.name, account_number:, account_number_confirmation: account_number, routing_number: "110000000", account_holder_full_name: "Synthetic Holder" }
            ))
  end

  def prepare_card
    chargeable = double("chargeable")
    allow(ChargeProcessor).to receive(:get_chargeable_for_params).and_return(chargeable)
    allow(CreditCard).to receive(:create).with(chargeable).and_return(create(:us_debit_stripe_credit_card))
    prepare(ActionController::Parameters.new(card: { stripe_token: "tok_synthetic" }))
  end

  def activate!(setup)
    result = StripePayoutRailSetups::Activate.new(setup:, activated_by: team_member, consent_reference: "support-thread-synthetic-10").process
    expect(result.success).to be(true)
    expect(StripePayoutProcessor.destination_merchant_account(seller.reload, [])).to eq(setup.merchant_account)
    setup.reload.activated_at
  end

  def eligible?
    seller.reload.eligible_for_instant_payouts?
  end

  it "seasons a staged debit card from its activation, not from when it was prepared" do
    setup = prepare_card
    travel_to(Time.current + seasoning + 30.days)
    expect(eligible?).to be(false)
    expect(seller.current_payout_processor).to eq(PayoutProcessorType::PAYPAL)

    activated_at = activate!(setup)

    expect(setup.merchant_account.reload.created_at).to be <= seasoning.ago
    expect(eligible?).to be(false)
    travel_to(activated_at + seasoning - 1.day)
    expect(eligible?).to be(false)
    travel_to(activated_at + seasoning + 1.minute)
    expect(eligible?).to be(true)
  end

  it "does not season a later account from cancelled or abandoned setups' accounts that never went live" do
    cancelled = prepare_bank("000123456789")
    expect(StripePayoutRailSetups::Cancel.new(setup: cancelled, cancelled_by: team_member, reason_reference: "support-thread-synthetic-10").process.success).to be(true)
    abandoned = prepare_bank("000111222333")
    StripePayoutRailSetup.abandon_open_for!(seller, :connect_removed)
    retired = [cancelled, abandoned].map { _1.reload.merchant_account.reload }
    expect(retired).to all(satisfy { |account| account.charge_processor_deleted? && account.charge_processor_alive_at.nil? })
    travel_to(Time.current + seasoning + 30.days)

    activated_at = activate!(prepare_bank("000222333444"))

    expect(retired.map(&:created_at)).to all(be <= seasoning.ago)
    expect(eligible?).to be(false)
    travel_to(activated_at + seasoning + 1.minute)
    expect(eligible?).to be(true)
  end

  it "still seasons a replacement account from an activated account that carried money and was later retired" do
    first = prepare_bank("000123456789")
    activate!(first)
    travel_to(Time.current + seasoning + 1.day)
    expect(eligible?).to be(true)

    first.merchant_account.reload.delete_charge_processor_account!
    replacement = create(:merchant_account, user: seller)

    expect(StripePayoutProcessor.destination_merchant_account(seller.reload, [])).to eq(replacement)
    expect(first.merchant_account.reload.charge_processor_alive_at).to be_nil
    expect(eligible?).to be(true)
  end
end
