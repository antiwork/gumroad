# frozen_string_literal: true

require "spec_helper"

# Activate and the abandonment paths run on separate connections against real InnoDB locks, so these
# cannot share the fixture transaction; cleanup is explicit. Each example parks one side inside its
# seller lock and lets the other run.
describe StripePayoutRailSetups::Activate, "racing abandonment" do
  include_context "with Stripe API stubs"

  self.use_transactional_tests = false

  let!(:seller) { create(:user, payment_address: "seller-payouts@example.com") }
  let!(:team_member) { create(:user, is_team_member: true) }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
  let!(:setup) do
    create(:user_compliance_info, user: seller)
    create(:tos_agreement, user: seller)
    Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
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
    expect(setup).to be_prepared
    @held = Queue.new
    @proceed = Queue.new
    candidate = setup.bank_account
    account_id = setup.merchant_account.charge_processor_merchant_id
    compliance_revision = seller.alive_user_compliance_info.external_id
    # Unit control for the provider readiness read.
    allow(Stripe::Account).to receive(:retrieve).with(account_id) do
      Stripe::Account.construct_from(
        id: account_id, country: "US", payouts_enabled: true, charges_enabled: true, metadata: { user_compliance_info_id: compliance_revision },
        requirements: { disabled_reason: nil },
        external_accounts: { object: "list", data: [{ id: candidate.stripe_bank_account_id, object: "bank_account", status: "new", currency: "usd", country: "US" }] }
      )
    end
  end

  after do
    @proceed << true << true
    @threads&.each do |thread|
      next if thread.join(10)

      thread.kill
      thread.join
    end
    user_ids = [seller.id, team_member.id]
    StripePayoutRailSetup.where(user_id: user_ids).delete_all
    BankAccount.where(user_id: user_ids).delete_all
    MerchantAccount.where(user_id: user_ids).delete_all
    UserComplianceInfo.where(user_id: user_ids).delete_all
    TosAgreement.where(user_id: user_ids).delete_all
    Comment.where(commentable_type: "User", commentable_id: user_ids).delete_all
    RefundPolicy.where(seller_id: user_ids).delete_all
    SellerProfile.where(seller_id: user_ids).delete_all
    PaperTrail::Version.where(item_type: "User", item_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
  end

  def in_thread(&block)
    thread = Thread.new { ApplicationRecord.connection_pool.with_connection(&block) }
    thread.report_on_exception = false
    (@threads ||= []) << thread
    thread
  end

  # True once `thread` has finished or is waiting on an InnoDB row lock.
  def finished_or_lock_waiting?(thread)
    10.times do
      return true unless thread.alive?
      return true if ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM sys.innodb_lock_waits").to_i.positive?

      sleep 0.15
    end
    false
  end

  def activate
    described_class.new(setup: StripePayoutRailSetup.find(setup.id), activated_by: team_member, consent_reference: "support-thread-synthetic-3").process
  end

  def expect_no_half_switched_rail
    final = StripePayoutRailSetup.find(setup.id)
    account = MerchantAccount.find(final.merchant_account_id)
    candidate = BankAccount.find(final.bank_account_id)
    user = User.find(seller.id)
    if final.state == StripePayoutRailSetup::ACTIVATED
      expect(account).to be_alive
      expect(account.charge_processor_alive?).to be(true)
      expect(candidate).to be_alive
      expect(user.stripe_account).to eq(account)
    else
      expect(final.state).to eq(StripePayoutRailSetup::FAILED)
      expect(account).not_to be_alive
      expect(candidate).to be_deleted
      expect(user.payment_address).to eq("seller-payouts@example.com")
      expect(user.stripe_account).to be_nil
    end
  end

  it "lets an activation that holds the seller lock finish, and the disconnect then leaves the live rail alone" do
    allow_any_instance_of(described_class).to receive(:compliance_synced?).and_wrap_original do |original, *args|
      if Thread.current[:park]
        @held << true
        @proceed.pop
      end
      original.call(*args)
    end
    activation = in_thread do
      Thread.current[:park] = true
      activate
    end
    @held.pop

    disconnect = in_thread { StripeMerchantAccountManager.disconnect(user: User.find(seller.id)) }
    expect(finished_or_lock_waiting?(disconnect)).to be(true)
    @proceed << true

    expect(activation.value.success).to be(true)
    disconnect.join
    expect(StripePayoutRailSetup.find(setup.id).state).to eq(StripePayoutRailSetup::ACTIVATED)
    expect_no_half_switched_rail
  end

  it "makes an activation that waits behind a disconnect refuse, keeping PayPal" do
    allow_any_instance_of(StripePayoutRailSetup).to receive(:mark_failed!).and_wrap_original do |original, *args|
      if Thread.current[:park]
        @held << true
        @proceed.pop
      end
      original.call(*args)
    end
    disconnect = in_thread do
      Thread.current[:park] = true
      StripeMerchantAccountManager.disconnect(user: User.find(seller.id))
    end
    @held.pop

    activation = in_thread { activate }
    expect(finished_or_lock_waiting?(activation)).to be(true)
    @proceed << true

    disconnect.join
    expect(activation.value.success).to be(false)
    expect(StripePayoutRailSetup.find(setup.id).state).to eq(StripePayoutRailSetup::FAILED)
    expect(User.find(seller.id).payment_address).to eq("seller-payouts@example.com")
    expect_no_half_switched_rail
  end
end
