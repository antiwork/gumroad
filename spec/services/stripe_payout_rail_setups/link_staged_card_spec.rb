# frozen_string_literal: true

require "spec_helper"

# SDK double for Stripe's idempotent requests: a key seen in the last 24 hours with the same parameters
# replays the stored response without applying anything; with other parameters Stripe refuses it. An
# older or missing key applies. Account.update with a token replaces the account's external account.
RSpec.shared_context "with an idempotent Stripe card-link double" do
  let(:stripe_double) { { tokens: {}, updates: {}, token_keys: [], update_keys: [], applied: [], external: nil, charges_enabled: false } }

  before do
    allow(Stripe::Token).to receive(:create) do |_params, opts = {}|
      key = opts[:idempotency_key]
      stripe_double[:token_keys] << key
      prior = key && stripe_double[:tokens][key]
      next prior[:token] if prior && prior[:at] > 24.hours.ago

      token = Stripe::Token.construct_from(id: "tok_synthetic_#{stripe_double[:token_keys].size}", object: "token")
      stripe_double[:tokens][key] = { token:, at: Time.current } if key
      token
    end
    allow(Stripe::Account).to receive(:update) do |account_id, params, opts = {}|
      key = opts&.[](:idempotency_key)
      stripe_double[:update_keys] << key
      prior = key && stripe_double[:updates][key]
      if prior && prior[:at] > 24.hours.ago
        raise Stripe::IdempotencyError.new("Keys for idempotent requests can only be used with the same parameters.") if prior[:params] != params

        next prior[:response]
      end
      stripe_double[:applied] << { account_id:, token: params[:bank_account] }
      stripe_double[:external] = "card_synthetic_#{stripe_double[:applied].size}"
      response = Stripe::Account.construct_from(id: account_id, object: "account")
      stripe_double[:updates][key] = { params:, response:, at: Time.current } if key
      stripe_double.delete(:during_update)&.call
      raise Stripe::APIConnectionError.new("Connection reset") if stripe_double.delete(:lose_next_update)

      response
    end
    allow(Stripe::Account).to receive(:retrieve) do |account_id, *_args|
      stripe_double.delete(:during_retrieve)&.call
      external = stripe_double[:external] && { id: stripe_double[:external], object: "card", fingerprint: "fp_#{stripe_double[:external]}", currency: "usd", country: "US",
                                               available_payout_methods: %w[standard instant] }
      Stripe::Account.construct_from(
        id: account_id, object: "account", country: "US", default_currency: "usd", charges_enabled: stripe_double[:charges_enabled], payouts_enabled: true,
        metadata: { user_compliance_info_id: seller.alive_user_compliance_info.external_id },
        requirements: { disabled_reason: nil, currently_due: [], past_due: [] },
        external_accounts: { object: "list", data: [external].compact }
      )
    end
  end

  def stage_card!(credit_card = create(:us_debit_stripe_credit_card))
    chargeable = double("chargeable")
    allow(ChargeProcessor).to receive(:get_chargeable_for_params).and_return(chargeable)
    allow(CreditCard).to receive(:create).with(chargeable).and_return(credit_card)
    StripePayoutRailSetups::Stage.new(seller:, params: ActionController::Parameters.new(card: { stripe_token: "tok_synthetic" })).process.setup
  end

  # Prepared and waiting for Stripe to enable charges, as Provision leaves a card setup.
  def awaiting_card_setup(credit_card = create(:us_debit_stripe_credit_card))
    setup = stage_card!(credit_card)
    expect(StripePayoutRailSetups::Provision.new(setup).process.success).to be(true)
    expect(setup.reload).to be_awaiting_card_link
    setup
  end

  def activate(setup)
    StripePayoutRailSetups::Activate.new(setup: StripePayoutRailSetup.find(setup.id), activated_by: team_member, consent_reference: "support-thread-synthetic-12").process
  end
end

describe StripePayoutRailSetups::LinkStagedCard do
  include_context "with Stripe API stubs"
  include_context "with an idempotent Stripe card-link double"

  let(:seller) { create(:user, payment_address: "seller-payouts@example.com") }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }
  let(:team_member) { create(:user, is_team_member: true) }

  before do
    create(:user_compliance_info, user: seller)
    create(:tos_agreement, user: seller)
    Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
  end

  { "within Stripe's key window" => 0, "after Stripe's keys expired" => 25.hours }.each do |description, later|
    it "does not replace the live card when an expired attempt resumes #{description}, after a newer attempt linked it and staff activated" do
      setup = awaiting_card_setup
      stripe_double[:charges_enabled] = true
      newer = nil
      activation = nil
      # The first worker reads the account, then stops past its lease; meanwhile a newer attempt links
      # the card and staff activate. Stripe then accepts the first worker's write but its response is lost.
      stripe_double[:during_retrieve] = lambda do
        travel(StripePayoutRailSetups::Provision::ATTEMPT_LEASE + 1.minute) do
          newer = described_class.new(StripePayoutRailSetup.find(setup.id)).process
          activation = activate(setup)
        end
        travel(later)
        stripe_double[:lose_next_update] = true
      end

      stale = described_class.new(setup).process

      expect(newer).to eq(:linked)
      expect(activation.success).to be(true)
      expect(stale).to eq(:not_awaiting)
      expect(stripe_double[:applied].size).to eq(1)
      live_card = BankAccount.find(setup.bank_account_id)
      expect(live_card).to be_alive
      expect(live_card.stripe_bank_account_id).to eq(stripe_double[:external])
      expect(setup.reload.state).to eq(StripePayoutRailSetup::ACTIVATED)
      expect(seller.reload.stripe_account).to eq(setup.merchant_account)
      expect(seller.active_bank_account).to eq(live_card)
    end
  end

  it "replays the same token and link after a lost response, so the retry records the card Stripe holds" do
    stripe_double[:charges_enabled] = true
    stripe_double[:lose_next_update] = true
    setup = stage_card!
    expect(StripePayoutRailSetups::Provision.new(setup).process.success).to be(true)
    expect(setup.reload).to be_awaiting_card_link
    expect(setup.bank_account.reload.stripe_bank_account_id).to be_nil
    expect(LinkStagedRailCardJob.jobs.size).to eq(1)

    LinkStagedRailCardJob.drain

    expect(setup.reload).to be_prepared
    expect(stripe_double[:applied].size).to eq(1)
    expect(stripe_double[:token_keys].size).to eq(2)
    expect(stripe_double[:token_keys].uniq.size).to eq(1)
    expect(stripe_double[:update_keys].size).to eq(2)
    expect(stripe_double[:update_keys].uniq.size).to eq(1)
    expect(stripe_double[:token_keys] + stripe_double[:update_keys]).to all(include(setup.id.to_s))
    expect(setup.bank_account.reload.stripe_bank_account_id).to eq(stripe_double[:external])
    expect(setup.bank_account).to be_deleted
    expect(setup.merchant_account.reload.charge_processor_alive?).to be(false)
    expect(seller.reload.stripe_account).to be_nil
  end

  it "keys a setup submitted after a cancel to that setup, so its card is linked rather than replayed" do
    stripe_double[:charges_enabled] = true
    stripe_double[:lose_next_update] = true
    cancelled = stage_card!
    StripePayoutRailSetups::Provision.new(cancelled).process
    expect(cancelled.reload).to be_awaiting_card_link
    expect(StripePayoutRailSetups::Cancel.new(setup: cancelled, cancelled_by: team_member, reason_reference: "support-thread-synthetic-12").process.success).to be(true)
    LinkStagedRailCardJob.drain
    expect(cancelled.reload.state).to eq(StripePayoutRailSetup::FAILED)

    setup = stage_card!(create(:us_debit_stripe_credit_card))
    expect(StripePayoutRailSetups::Provision.new(setup).process.success).to be(true)

    expect(setup.reload).to be_prepared
    expect(stripe_double[:applied].map { _1[:account_id] }).to eq([cancelled.merchant_account.charge_processor_merchant_id, setup.merchant_account.charge_processor_merchant_id])
    expect(stripe_double[:update_keys].uniq.size).to eq(2)
    expect(stripe_double[:update_keys].last).to include(setup.id.to_s)
    expect(setup.bank_account.reload.stripe_bank_account_id).to eq(stripe_double[:external])
  end
end

# The newer attempt and the old worker run on separate connections against real InnoDB locks, so this
# cannot share the fixture transaction; cleanup is explicit.
describe StripePayoutRailSetups::LinkStagedCard, "while an old attempt is writing to Stripe" do
  include_context "with Stripe API stubs"
  include_context "with an idempotent Stripe card-link double"

  self.use_transactional_tests = false

  let!(:seller) { create(:user, payment_address: "seller-payouts@example.com") }
  let!(:team_member) { create(:user, is_team_member: true) }
  let!(:connect_account) { create(:merchant_account_stripe_connect, user: seller) }

  before do
    create(:user_compliance_info, user: seller)
    create(:tos_agreement, user: seller)
    Feature.activate_user(User::FeatureStatus::PAYOUT_RAIL_BESIDE_INACTIVE_CONNECT_FEATURE, seller)
    @held = Queue.new
    @proceed = Queue.new
  end

  after do
    @proceed << true << true
    @threads&.each do |thread|
      next if thread.join(10)

      thread.kill
      thread.join
    end
    user_ids = [seller.id, team_member.id]
    credit_card_ids = BankAccount.where(user_id: user_ids).where.not(credit_card_id: nil).pluck(:credit_card_id)
    StripePayoutRailSetup.where(user_id: user_ids).delete_all
    BankAccount.where(user_id: user_ids).delete_all
    CreditCard.where(id: credit_card_ids).delete_all
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

  def lock_waiting?(thread)
    10.times do
      return false unless thread.alive?
      return true if ApplicationRecord.connection.select_value("SELECT COUNT(*) FROM sys.innodb_lock_waits").to_i.positive?

      sleep 0.15
    end
    false
  end

  it "makes a newer attempt that reclaims the expired lease wait for the write, then find the card linked" do
    setup = awaiting_card_setup
    stripe_double[:charges_enabled] = true
    stripe_double[:during_update] = lambda do
      @held << true
      @proceed.pop
    end
    old = in_thread { described_class.new(StripePayoutRailSetup.find(setup.id)).process }
    @held.pop
    travel(StripePayoutRailSetups::Provision::ATTEMPT_LEASE + 1.minute)

    newer = in_thread { described_class.new(StripePayoutRailSetup.find(setup.id)).process }
    expect(lock_waiting?(newer)).to be(true)
    expect(stripe_double[:update_keys].size).to eq(1)
    @proceed << true

    expect(old.value).to eq(:linked)
    expect(newer.value).to eq(:not_awaiting)
    expect(stripe_double[:applied].size).to eq(1)
    final = StripePayoutRailSetup.find(setup.id)
    expect(final).to be_prepared
    expect(BankAccount.find(final.bank_account_id).stripe_bank_account_id).to eq(stripe_double[:external])
    expect(User.find(seller.id).stripe_account).to be_nil
  end
end
