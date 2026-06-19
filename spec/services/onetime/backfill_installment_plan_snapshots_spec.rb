# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillInstallmentPlanSnapshots do
  describe "#process" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, price_cents: 1000) }
    let!(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 4) }
    let(:offer_code) { create(:offer_code, products: [product], amount_cents: 200) }
    let(:buyer) { create(:user) }
    let!(:purchase) { create(:installment_plan_purchase, link: product, offer_code:, purchaser: buyer) }
    let(:subscription) { purchase.subscription }

    # Simulate a legacy subscription created before the snapshot feature: drop the snapshot the
    # factory creates and pin the originally-agreed installment count on the subscription.
    def make_legacy!
      subscription.update!(charge_occurrence_count: 4)
      subscription.last_payment_option.installment_plan_snapshot&.destroy
      subscription.last_payment_option.reload
    end

    it "backfills a snapshot reconstructing the agreed discounted total" do
      make_legacy!

      expect { described_class.process(dry_run: false) }
        .to change { subscription.last_payment_option.reload.installment_plan_snapshot }.from(nil)

      snapshot = subscription.last_payment_option.installment_plan_snapshot
      expect(snapshot.total_price_cents).to eq(800) # (1000 - 200) * 1
      expect(snapshot.number_of_installments).to eq(4)
      expect(snapshot.recurrence).to eq(installment_plan.recurrence)
    end

    it "freezes the agreed price against later product price and offer code changes" do
      make_legacy!
      described_class.process(dry_run: false)

      product.update!(price_cents: 2000)
      offer_code.mark_deleted!

      expect(Subscription.find(subscription.id).current_subscription_price_cents).to eq(200) # 800 / 4, not drifted
    end

    it "does not write anything in dry run mode" do
      make_legacy!

      expect { described_class.process(dry_run: true) }
        .not_to change { subscription.last_payment_option.reload.installment_plan_snapshot }
    end

    it "is idempotent and skips subscriptions that already have a snapshot" do
      make_legacy!
      described_class.process(dry_run: false)
      existing = subscription.last_payment_option.installment_plan_snapshot

      stats = described_class.process(dry_run: false)

      expect(subscription.last_payment_option.reload.installment_plan_snapshot).to eq(existing)
      expect(stats[:skipped_has_snapshot]).to eq(1)
      expect(stats[:created]).to eq(0)
    end

    it "skips subscriptions whose installments are already fully charged" do
      make_legacy!
      subscription.update!(charge_occurrence_count: 1) # already 1 successful charge -> completed

      stats = described_class.process(dry_run: false)

      expect(subscription.last_payment_option.reload.installment_plan_snapshot).to be_nil
      expect(stats[:skipped_completed]).to eq(1)
    end

    it "skips subscriptions without a cached offer code discount" do
      no_discount_purchase = create(:installment_plan_purchase, link: product, purchaser: create(:user))
      sub = no_discount_purchase.subscription
      sub.update!(charge_occurrence_count: 4)
      sub.last_payment_option.installment_plan_snapshot&.destroy

      described_class.process(dry_run: false)

      expect(sub.last_payment_option.reload.installment_plan_snapshot).to be_nil
    end
  end
end
