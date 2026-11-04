# frozen_string_literal: true

require "spec_helper"

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
end
