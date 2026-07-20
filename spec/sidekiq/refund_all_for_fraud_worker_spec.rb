# frozen_string_literal: true

require "spec_helper"

describe RefundAllForFraudWorker do
  let!(:gumroad_merchant_account) { create(:merchant_account, user: nil) }
  let(:admin_user) { create(:admin_user) }
  let(:user) { create(:compliant_user, user_risk_state: "suspended_for_fraud") }
  let(:product) { create(:product, user:) }

  def create_refundable_purchase(overrides = {})
    create(:purchase, { seller: user, link: product, stripe_transaction_id: "ch_test", stripe_refunded: false }.merge(overrides))
  end

  it "uses a unique execution lock" do
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
  end

  it "locks by user id only" do
    expect(described_class.lock_args([123, 456, true])).to eq([123])
  end

  describe ".refundable_purchases_for" do
    it "includes chargeback-reversed purchases and excludes refunded, charged-back, and failed ones" do
      refundable = create_refundable_purchase
      create_refundable_purchase(stripe_refunded: true)
      charged_back = create_refundable_purchase
      charged_back.update_columns(chargeback_date: 1.day.ago)
      reversed = create_refundable_purchase
      reversed.update_columns(chargeback_date: 1.day.ago, flags: reversed.flags | Purchase.flag_mapping["flags"][:chargeback_reversed])
      create(:failed_purchase, seller: user, link: product)

      expect(described_class.refundable_purchases_for(user)).to match_array([refundable, reversed])
    end
  end

  describe "#perform" do
    it "does nothing when the user is not suspended" do
      compliant = create(:compliant_user)
      create(:purchase, seller: compliant, link: create(:product, user: compliant), stripe_transaction_id: "ch_test")

      expect do
        described_class.new.perform(compliant.id, admin_user.id, false)
      end.not_to change { RefundPurchaseForFraudWorker.jobs.size }

      expect(compliant.comments.count).to eq(0)
    end

    it "fans out one per-purchase job per refundable purchase and leaves a comment with the queued count" do
      purchase_one = create_refundable_purchase
      purchase_two = create_refundable_purchase
      create_refundable_purchase(stripe_refunded: true)

      expect do
        described_class.new.perform(user.id, admin_user.id, false)
      end.to change { RefundPurchaseForFraudWorker.jobs.size }.by(2)

      expect(RefundPurchaseForFraudWorker).to have_enqueued_sidekiq_job(purchase_one.id, admin_user.id, false)
      expect(RefundPurchaseForFraudWorker).to have_enqueued_sidekiq_job(purchase_two.id, admin_user.id, false)

      comment = user.comments.last
      expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_REFUND_ALL_FOR_FRAUD)
      expect(comment.author_id).to eq(admin_user.id)
      expect(comment.content).to include("2 purchases queued for refund")
      expect(comment.content).to include("buyers will not be blocked")
    end

    it "passes block_buyers through to the per-purchase jobs and notes it in the comment" do
      purchase = create_refundable_purchase

      described_class.new.perform(user.id, admin_user.id, true)

      expect(RefundPurchaseForFraudWorker).to have_enqueued_sidekiq_job(purchase.id, admin_user.id, true)
      expect(user.comments.last.content).to include("buyers will be blocked")
    end
  end
end
