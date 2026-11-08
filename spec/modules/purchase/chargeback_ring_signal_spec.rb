# frozen_string_literal: true

require "spec_helper"

describe Purchase::ChargebackRingSignal do
  before do
    # The purchase factory reaches for MerchantAccount.gumroad, which is only seeded in CI.
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
  end

  let(:hosting_ip) { "151.240.10.#{rand(1..250)}" }

  def seed_paid_sales(seller, count:, card_country: "BR", hosting: true, created_at: 5.days.ago)
    product = create(:product, user: seller, price_cents: 2200)
    count.times.map do |i|
      ip = hosting ? "151.240.#{i % 250}.#{(i % 250) + 1}" : "88.12.#{i % 250}.#{(i % 250) + 1}"
      create(:purchase, link: product, seller:, card_country:, ip_address: ip, created_at:)
    end
  end

  def build_checkout_purchase(seller)
    product = create(:product, user: seller, price_cents: 2200)
    build(:purchase, link: product, seller:, card_country: "BR", ip_address: "151.240.99.99")
  end

  describe "thresholds" do
    it "ships the measured rule" do
      expect(described_class::MIN_PAID_SALES).to eq(3)
      expect(described_class::DOMINANT_CARD_COUNTRY_SHARE_PCT).to eq(90.0)
      expect(described_class::HOSTING_IP_SHARE_PCT).to eq(80.0)
      expect(described_class::MAX_SELLER_AGE_DAYS).to eq(120)
      expect(described_class::HOSTING_CIDR_STRINGS).to include("151.240.0.0/16")
    end
  end

  describe ".evaluate" do
    it "returns a hit with the numbers that produced it when all four clauses hold" do
      seller = create(:user, created_at: 10.days.ago)
      seed_paid_sales(seller, count: 10)

      result = described_class.evaluate(seller:)

      expect(result.hit?).to be(true)
      expect(result.paid_sales).to eq(10)
      expect(result.dominant_card_country).to eq("BR")
      expect(result.dominant_share_pct).to eq(100.0)
      expect(result.hosting_share_pct).to eq(100.0)
      expect(result.matched_cidr).to eq("151.240.0.0/16")
      expect(result.distinct_browsers).to be >= 1
    end

    it "allows when there are fewer than #{described_class::MIN_PAID_SALES} paid sales" do
      seller = create(:user, created_at: 10.days.ago)
      seed_paid_sales(seller, count: 2)

      expect(described_class.evaluate(seller:).hit?).to be(false)
    end

    it "allows when no single card country reaches the dominance threshold" do
      seller = create(:user, created_at: 10.days.ago)
      seed_paid_sales(seller, count: 8, card_country: "BR")
      seed_paid_sales(seller, count: 2, card_country: "US")

      result = described_class.evaluate(seller:)
      expect(result.dominant_share_pct).to eq(80.0)
      expect(result.hit?).to be(false)
    end

    it "allows when the hosting-IP share is below the threshold (young seller, one country, residential IPs)" do
      seller = create(:user, created_at: 10.days.ago)
      seed_paid_sales(seller, count: 5, hosting: false)

      result = described_class.evaluate(seller:)
      expect(result.dominant_share_pct).to eq(100.0)
      expect(result.hosting_share_pct).to eq(0.0)
      expect(result.hit?).to be(false)
    end

    it "allows when the seller account is older than #{described_class::MAX_SELLER_AGE_DAYS} days" do
      seller = create(:user, created_at: 200.days.ago)
      seed_paid_sales(seller, count: 10)

      result = described_class.evaluate(seller:)
      expect(result.hit?).to be(false)
      expect(result.paid_sales).to be_nil # early return: the bounded query never ran
    end

    it "ignores free and older-than-window sales" do
      seller = create(:user, created_at: 10.days.ago)
      product = create(:product, user: seller, price_cents: 0)
      3.times { create(:purchase, link: product, seller:, price_cents: 0, stripe_fingerprint: nil, stripe_transaction_id: nil, ip_address: hosting_ip) }
      seed_paid_sales(seller, count: 5, created_at: 45.days.ago)

      result = described_class.evaluate(seller:)
      expect(result.paid_sales).to eq(0)
      expect(result.hit?).to be(false)
    end
  end

  describe "checkout integration" do
    context "when the flag is off (default)" do
      it "never calls evaluate and changes nothing" do
        seller = create(:user, created_at: 10.days.ago)
        seed_paid_sales(seller, count: 5)
        purchase = build_checkout_purchase(seller)

        expect(described_class).not_to receive(:evaluate)
        expect { purchase.save! }.not_to change { ChargebackRingSignal.count }
        expect(purchase.errors).to be_empty
      end
    end

    context "when the flag is on for the seller" do
      let(:seller) { create(:user, created_at: 10.days.ago) }

      # Seeding runs with the flag OFF (the seed purchases would otherwise trip the signal
      # themselves); each example turns the flag on after its history is in place.
      def arm_flag = Feature.activate_user(described_class::FEATURE_FLAG, seller)

      it "refuses the purchase with a generic message, writes a blocked telemetry row, and pauses payouts" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        purchase = build_checkout_purchase(seller)

        allow(ErrorNotifier).to receive(:notify)

        purchase.save

        expect(purchase.errors.full_messages).to eq(["Your card was not charged."])
        expect(purchase.errors.full_messages.join).not_to match(/fraud|seller|ring|block/i)
        expect(purchase.error_code).to eq(PurchaseErrorCode::CHARGEBACK_RING_SIGNAL)
        expect(purchase).to be_persisted

        row = ChargebackRingSignal.last
        expect(row.seller_id).to eq(seller.id)
        expect(row.purchase_id).to eq(purchase.id)
        expect(row.decision).to eq("blocked")
        expect(row.paid_sales).to eq(5)
        expect(row.dominant_card_country).to eq("BR")
        expect(row.dominant_share_pct).to eq(100.0)
        expect(row.hosting_share_pct).to eq(100.0)
        expect(row.matched_cidr).to eq("151.240.0.0/16")

        seller.reload
        expect(seller.payouts_paused_internally?).to be(true)
        expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        expect(seller.comments.with_type_on_probation.last.author_name)
          .to eq(User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:chargeback_ring_signal])
        # The hold must NOT read as a chargeback-rate hold, or the automatic rate-recovery
        # release would lift it while the ring's disputes are still in flight.
        expect(seller.payouts_paused_for_chargeback_rate?).to be(false)
        expect(ErrorNotifier).to have_received(:notify).with(a_string_including("chargeback_ring_signal blocked"))
      end

      it "allows a young legitimate seller with one-country buyers on residential IPs and records the allowed side" do
        seed_paid_sales(seller, count: 5, hosting: false)
        arm_flag
        purchase = build_checkout_purchase(seller)

        expect { purchase.save! }.to change { ChargebackRingSignal.count }.by(1)
        expect(purchase.errors).to be_empty

        row = ChargebackRingSignal.last
        expect(row.decision).to eq("allowed")
        expect(row.paid_sales).to eq(5)
        expect(row.hosting_share_pct).to eq(0.0)
      end

      it "fails open on an exception: the purchase is allowed and an error row is written" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        purchase = build_checkout_purchase(seller)

        allow(described_class).to receive(:evaluate).and_raise(Timeout::Error)
        allow(ErrorNotifier).to receive(:notify)

        expect { purchase.save! }.to change { ChargebackRingSignal.where(decision: "error").count }.by(1)
        expect(purchase.errors).to be_empty
        expect(seller.reload.payouts_paused_internally?).to be(false)
        expect(ErrorNotifier).to have_received(:notify).with(instance_of(Timeout::Error), hash_including(:seller_id))
      end

      it "does not stack on top of an admin payout pause" do
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_ADMIN)
        seed_paid_sales(seller, count: 5)
        arm_flag
        purchase = build_checkout_purchase(seller)

        allow(ErrorNotifier).to receive(:notify)
        purchase.save

        expect(purchase.error_code).to eq(PurchaseErrorCode::CHARGEBACK_RING_SIGNAL)
        expect(seller.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
      end

      it "skips recurring subscription charges" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        purchase = build_checkout_purchase(seller)
        allow(purchase).to receive(:is_recurring_subscription_charge).and_return(true)

        expect(described_class).not_to receive(:evaluate)
        # Invoke the hook directly: making the factory purchase a full recurring charge drags in
        # unrelated subscription plumbing, and the guard under test is the first thing the hook does.
        purchase.send(:check_for_chargeback_ring_signal)
        expect(purchase.errors).to be_empty
        expect(purchase.error_code).to be_nil
      end

      it "writes no telemetry row below the volume floor" do
        seed_paid_sales(seller, count: 1)
        arm_flag
        purchase = build_checkout_purchase(seller)

        expect { purchase.save! }.not_to change { ChargebackRingSignal.count }
        expect(purchase.errors).to be_empty
      end
    end
  end
end
