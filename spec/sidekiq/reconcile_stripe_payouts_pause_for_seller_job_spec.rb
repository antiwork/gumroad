# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe ReconcileStripePayoutsPauseForSellerJob do
  let(:seller) { create(:user) }
  let(:merchant_account) { create(:merchant_account, user: seller) }

  def pause_by_stripe!(user = seller)
    user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
    user.comments.create!(
      content: "Payouts automatically paused by Stripe (disabled reason: requirements.past_due).",
      comment_type: Comment::COMMENT_TYPE_PAYOUTS_PAUSED,
      author_name: StripeMerchantAccountManager::STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR
    )
  end

  def stub_stripe_account(payouts_enabled)
    allow(Stripe::Account).to receive(:retrieve).and_return({ "payouts_enabled" => payouts_enabled })
  end

  def deliver_account_updated(payouts_enabled:, account: merchant_account)
    StripeMerchantAccountManager.handle_stripe_event(
      "id" => "evt_reconcile_spec",
      "type" => "account.updated",
      "data" => {
        "object" => {
          "id" => account.charge_processor_merchant_id,
          "object" => "account",
          "type" => "custom",
          "business_type" => "individual",
          "charges_enabled" => true,
          "payouts_enabled" => payouts_enabled,
          "default_currency" => "usd",
          "country" => "US",
          "requirements" => {
            "currently_due" => [], "eventually_due" => [], "past_due" => [], "errors" => [],
            "disabled_reason" => payouts_enabled ? nil : "requirements.pending_verification"
          },
          "future_requirements" => { "currently_due" => [], "past_due" => [], "errors" => [] }
        },
        "previous_attributes" => {}
      }
    )
  end

  before { merchant_account }

  context "when Stripe reports payouts enabled" do
    before do
      pause_by_stripe!
      stub_stripe_account(true)
    end

    it "resumes the pause and leaves the same audit comment the webhook writes" do
      described_class.new.perform(seller.id)

      seller.reload
      expect(seller.payouts_paused_internally?).to be(false)
      expect(seller.payouts_paused_by_source).to be_nil
      expect(seller.comments.with_type_payouts_resumed.last.author_name)
        .to eq(StripeMerchantAccountManager::STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR)
    end

    it "does nothing on a second run" do
      described_class.new.perform(seller.id)

      expect do
        described_class.new.perform(seller.id)
      end.to_not change { seller.reload.comments.with_type_payouts_resumed.count }
    end

    it "clears the pause-email marker so a later pause can email the seller again" do
      merchant_account.update!(stripe_payouts_pause_email_sent: "action_required")

      described_class.new.perform(seller.id)

      expect(merchant_account.reload.stripe_payouts_pause_email_sent).to be_nil
    end

    it "does not resume from a read of an account that was replaced in the meantime" do
      allow(Stripe::Account).to receive(:retrieve) do
        merchant_account.delete_charge_processor_account!
        create(:merchant_account, user: seller)
        { "payouts_enabled" => true }
      end

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)
      expect(seller.comments.with_type_payouts_resumed).to be_empty
    end
  end

  context "when an unaccounted payout hold landed under the Stripe pause" do
    before do
      pause_by_stripe!
      stub_stripe_account(true)
      payment = create(:payment_failed, user: seller, processor: PayoutProcessorType::STRIPE, stripe_internal_transfer_id: "tr_unaccounted")
      StripePayoutProcessor.send(:hold_payouts_for_unaccounted_money!, payment, Payment::FailureReason::PAYOUT_OUTCOME_UNKNOWN)
    end

    it "leaves the pause for a human to reconcile" do
      expect(seller.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)
      expect(seller.comments.with_type_payouts_resumed).to be_empty
    end

    it "resumes a later Stripe pause once that hold was resumed" do
      travel 1.minute
      seller.update!(payouts_paused_internally: false, payouts_paused_by: nil)
      seller.comments.create!(content: "Payouts resumed after reconciling the transfer.", comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED, author_name: "admin")
      travel 1.minute
      pause_by_stripe!

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally?).to be(false)
    end
  end

  context "when account.updated deliveries land while the Stripe read is in flight" do
    before { deliver_account_updated(payouts_enabled: false) }

    it "keeps the pause when Stripe reports payouts disabled again for the same reason" do
      email_claim = merchant_account.reload.stripe_payouts_pause_email_claim_token
      allow(Stripe::Account).to receive(:retrieve) do
        # An unchanged reason writes no new pause comment, so only the disabled report itself can tell the
        # job its enabled read is stale.
        deliver_account_updated(payouts_enabled: false)
        { "payouts_enabled" => true }
      end

      expect do
        described_class.new.perform(seller.id)
      end.not_to change { seller.reload.comments.count }

      expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)
      expect(merchant_account.reload.stripe_payouts_pause_email_claim_token).to eq(email_claim)
    end

    it "keeps a pause Stripe re-applied after an enabled delivery resumed the previous one" do
      allow(Stripe::Account).to receive(:retrieve) do
        deliver_account_updated(payouts_enabled: true)
        deliver_account_updated(payouts_enabled: false)
        { "payouts_enabled" => true }
      end

      described_class.new.perform(seller.id)

      seller.reload
      expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)
      expect(seller.comments.with_type_payouts_resumed.count).to eq(1)
      expect(seller.comments.order(:id).last.comment_type).to eq(Comment::COMMENT_TYPE_PAYOUTS_PAUSED)
      merchant_account.reload
      expect(merchant_account.stripe_payouts_pause_email_sent).to eq("under_review")
      expect(StripePayoutsPausedEmailJob).to have_enqueued_sidekiq_job(
        seller.id, merchant_account.id, "under_review", merchant_account.stripe_payouts_pause_email_claim_token
      )
    end

    it "lets a disabled delivery that lands after the resume pause the seller and email them again" do
      stub_stripe_account(true)
      described_class.new.perform(seller.id)
      expect(seller.reload.payouts_paused_internally?).to be(false)
      StripePayoutsPausedEmailJob.clear

      deliver_account_updated(payouts_enabled: false)

      expect(seller.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)
      expect(seller.comments.order(:id).last.comment_type).to eq(Comment::COMMENT_TYPE_PAYOUTS_PAUSED)
      expect(StripePayoutsPausedEmailJob).to have_enqueued_sidekiq_job(seller.id, merchant_account.id, "under_review", anything)
    end
  end

  context "when Stripe still reports payouts disabled" do
    before do
      pause_by_stripe!
      stub_stripe_account(false)
    end

    it "leaves the pause in place" do
      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally?).to be(true)
      expect(seller.comments.with_type_payouts_resumed).to be_empty
    end
  end

  context "when the pause did not come from Stripe" do
    before { stub_stripe_account(true) }

    it "does not touch an admin pause" do
      seller.update!(payouts_paused_internally: true, payouts_paused_by: User.last.id)

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally?).to be(true)
      expect(seller.comments.with_type_payouts_resumed).to be_empty
    end

    it "does not call Stripe when payouts are not paused at all" do
      expect(Stripe::Account).to_not receive(:retrieve)

      described_class.new.perform(seller.id)
    end
  end

  context "when the pause came from Stripe but the account is suspended" do
    before do
      stub_stripe_account(true)
    end

    it "leaves the pause for a human to decide" do
      seller.update!(user_risk_state: "suspended_for_fraud")
      pause_by_stripe!

      described_class.new.perform(seller.id)

      expect(seller.reload.payouts_paused_internally?).to be(true)
      expect(seller.comments.with_type_payouts_resumed).to be_empty
    end
  end

  describe "the account.updated webhook path" do
    # Guard against the two callers drifting apart: the webhook must go through the same writer this
    # job calls, or one of them silently stops matching the other.
    it "resumes through the shared writer" do
      pause_by_stripe!
      expect(StripeMerchantAccountManager).to receive(:resume_stripe_payouts_pause!).and_call_original

      StripeMerchantAccountManager.handle_stripe_info_requirements(
        "evt_reconcile_spec",
        {
          "id" => merchant_account.charge_processor_merchant_id,
          "object" => "account",
          "type" => "custom",
          "business_type" => "individual",
          "charges_enabled" => true,
          "payouts_enabled" => true,
          "default_currency" => "usd",
          "country" => "US",
          "requirements" => { "currently_due" => [], "eventually_due" => [], "past_due" => [], "errors" => [] },
          "future_requirements" => { "currently_due" => [], "past_due" => [], "errors" => [] }
        },
        {}
      )

      expect(seller.reload.payouts_paused_internally?).to be(false)
      expect(seller.comments.with_type_payouts_resumed.last.author_name)
        .to eq(StripeMerchantAccountManager::STRIPE_PAYOUTS_SYNC_COMMENT_AUTHOR)
    end
  end

  describe "racing a disabled account.updated delivery on another connection" do
    # The webhook and this job only serialize through the user row lock, so this needs real separate
    # connections rather than the fixture transaction; cleanup is explicit.
    self.use_transactional_tests = false

    def job_lock_wait_observed?(connection_id)
      Timeout.timeout(5) do
        sleep 0.05 until ApplicationRecord.connection.select_value(<<~SQL, nil, [connection_id]).positive?
          SELECT COUNT(*) FROM performance_schema.data_lock_waits waits
          JOIN performance_schema.threads threads ON threads.THREAD_ID = waits.REQUESTING_THREAD_ID
          WHERE threads.PROCESSLIST_ID = ?
        SQL
        true
      end
    rescue Timeout::Error
      false
    end

    after do
      Comment.where(commentable_type: "User", commentable_id: seller.id).delete_all
      MerchantAccount.where(user_id: seller.id).delete_all
      RefundPolicy.where(seller_id: seller.id).delete_all
      GlobalAffiliate.where(affiliate_user_id: seller.id).delete_all
      User.where(id: seller.id).delete_all
    end

    it "waits for the webhook's lock and then leaves its pause in place" do
      deliver_account_updated(payouts_enabled: false)
      job_read_stripe = Queue.new
      webhook_holds_lock = Queue.new
      release_webhook = Queue.new
      allow(Stripe::Account).to receive(:retrieve) do
        job_read_stripe << true
        Timeout.timeout(5) { webhook_holds_lock.pop }
        { "payouts_enabled" => true }
      end
      allow(StripeMerchantAccountManager).to receive(:claim_stripe_payouts_pause_email).and_wrap_original do |method, *args|
        webhook_holds_lock << true
        release_webhook.pop
        method.call(*args)
      end
      job_connection_id = Queue.new
      threads = []

      begin
        threads << Thread.new do
          ApplicationRecord.connection_pool.with_connection do |connection|
            job_connection_id << connection.select_value("SELECT CONNECTION_ID()")
            described_class.new.perform(seller.id)
          end
        end
        Timeout.timeout(5) { job_read_stripe.pop }
        threads << Thread.new do
          ApplicationRecord.connection_pool.with_connection { deliver_account_updated(payouts_enabled: false) }
        end
        job_waited_for_webhook_lock = job_lock_wait_observed?(job_connection_id.pop)
        release_webhook << true
        Timeout.timeout(10) { threads.each(&:value) }

        expect(job_waited_for_webhook_lock).to be(true)
        expect(seller.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)
        expect(seller.comments.with_type_payouts_resumed).to be_empty
        expect(merchant_account.reload.stripe_payouts_pause_email_sent).to eq("under_review")
      ensure
        release_webhook << true
        threads.each { _1.kill if _1.alive? }
        threads.each(&:join)
      end
    end
  end
end
