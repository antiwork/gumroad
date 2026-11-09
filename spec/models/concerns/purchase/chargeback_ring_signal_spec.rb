# frozen_string_literal: true

require "spec_helper"

describe Purchase::ChargebackRingSignal do
  before do
    # The purchase factory reaches for MerchantAccount.gumroad, which is only seeded in CI.
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
  end

  def seed_paid_sales(seller, count:, card_country: "BR", hosting: true, created_at: 5.days.ago)
    product = create(:product, user: seller, price_cents: 2200)
    count.times.map do |i|
      ip = hosting ? "151.240.#{i % 250}.#{(i % 250) + 1}" : "88.12.#{i % 250}.#{(i % 250) + 1}"
      create(:purchase, link: product, seller:, card_country:, ip_address: ip, created_at:)
    end
  end

  def build_checkout_purchase(seller, card_country: "BR", ip_address: "151.240.99.99")
    product = create(:product, user: seller, price_cents: 2200)
    build(:purchase, link: product, seller:, card_country:, ip_address:)
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

    it "serves a multi-item cart from one query via the per-seller cache" do
      seller = create(:user, created_at: 10.days.ago)
      seed_paid_sales(seller, count: 5)

      expect(described_class).to receive(:evaluate_uncached).once.and_call_original
      2.times { described_class.evaluate(seller:) }
    end

    it "ignores free and older-than-window sales" do
      seller = create(:user, created_at: 10.days.ago)
      product = create(:product, user: seller, price_cents: 0)
      3.times { create(:purchase, link: product, seller:, price_cents: 0, stripe_fingerprint: nil, stripe_transaction_id: nil, ip_address: "151.240.1.1") }
      seed_paid_sales(seller, count: 5, created_at: 45.days.ago)

      result = described_class.evaluate(seller:)
      expect(result.paid_sales).to eq(0)
      expect(result.hit?).to be(false)
    end
  end

  describe "checkout integration" do
    context "when chargeback_ring_signal is off (default)" do
      it "never calls evaluate and changes nothing" do
        seller = create(:user, created_at: 10.days.ago)
        seed_paid_sales(seller, count: 5)
        purchase = build_checkout_purchase(seller)

        expect(described_class).not_to receive(:evaluate)
        expect { purchase.save! }.not_to change { ChargebackRingSignal.count }
        expect(purchase.errors).to be_empty
        expect(seller.reload.payouts_paused_internally?).to be(false)
      end
    end

    context "when chargeback_ring_signal is on (shadow)" do
      let(:seller) { create(:user, created_at: 10.days.ago) }

      # Seeding runs with the flag OFF (the seed purchases would otherwise trip the signal
      # themselves); each example turns the flag on after its history is in place.
      def arm_flag = Feature.activate_user(described_class::FEATURE_FLAG, seller)

      it "never refuses the purchase, but records telemetry, pauses payouts, flags the seller and alerts ops" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        purchase = build_checkout_purchase(seller)

        allow(ErrorNotifier).to receive(:notify)

        expect { purchase.save! }.to change { ChargebackRingSignal.count }.by(1)
        expect(purchase.errors).to be_empty
        expect(purchase.error_code).to be_nil

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
        expect(seller.payouts_paused_for_chargeback_ring_signal?).to be(true)
        # The hold must NOT read as a chargeback-rate hold, or the automatic rate-recovery
        # release would lift it while the ring's disputes are still in flight.
        expect(seller.payouts_paused_for_chargeback_rate?).to be(false)
        expect(seller.flagged_for_fraud?).to be(true)
        expect(ErrorNotifier).to have_received(:notify).with(a_string_including("chargeback_ring_signal hit"))
      end

      it "records the ring hold on top of an existing SYSTEM chargeback-rate hold so the rate-recovery job cannot lift it" do
        seed_paid_sales(seller, count: 5)
        # Pre-existing automatic chargeback-rate hold.
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
        seller.comments.create!(
          content: "rate hold",
          comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
          author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate]
        )
        expect(seller.payouts_paused_for_chargeback_rate?).to be(true)
        arm_flag

        allow(ErrorNotifier).to receive(:notify)
        build_checkout_purchase(seller).save!

        seller.reload
        expect(seller.payouts_paused_for_chargeback_ring_signal?).to be(true)
        expect(seller.payouts_paused_for_chargeback_rate?).to be(false)
        expect(seller.payouts_paused_internally?).to be(true)
      end

      it "does not append a second comment when the ring hold is already the newest" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        allow(ErrorNotifier).to receive(:notify)

        build_checkout_purchase(seller).save!
        expect { build_checkout_purchase(seller).save! }
          .not_to change { seller.comments.with_type_on_probation.count }
      end

      # A hit stays a hit for the whole window, so containment keyed on "is the seller paused
      # right now" would undo a human's release on the seller's very next sale. Ring sellers are
      # not suspended: they keep selling while a human reviews the account.
      it "keeps a human's release: a later sale does not re-pause, re-flag or re-comment" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        allow(ErrorNotifier).to receive(:notify)
        build_checkout_purchase(seller).save!
        expect(seller.reload.payouts_paused_for_chargeback_ring_signal?).to be(true)

        # The human review: the admin console's payout resume, then the risk queue's verdict.
        reviewer = create(:user)
        seller.update!(payouts_paused_internally: false, payouts_paused_by: nil)
        seller.comments.create!(
          author_id: reviewer.id,
          comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED,
          content: "Payouts resumed."
        )
        seller.mark_compliant!(author_id: reviewer.id)
        expect(seller.reload.flagged_for_fraud?).to be(false)

        # Still evaluates as a hit, so observation continues...
        expect { build_checkout_purchase(seller).save! }.to change { ChargebackRingSignal.count }.by(1)

        # ...but the decision the human made is not re-imposed.
        seller.reload
        expect(seller.payouts_paused_internally?).to be(false)
        expect(seller.flagged_for_fraud?).to be(false)
        expect(
          seller.comments.with_type_on_probation
                .where(author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:chargeback_ring_signal]).count
        ).to eq(1)
      end

      # Over an admin pause the ring skips its pause step, so its fraud flag is the only
      # containment record a human decision can be measured against.
      context "when the seller was already paused by an admin" do
        let(:reviewer) { create(:user) }

        before do
          seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_ADMIN)
          seed_paid_sales(seller, count: 5)
          arm_flag
          allow(ErrorNotifier).to receive(:notify)
          build_checkout_purchase(seller).save!
          expect(seller.reload.flagged_for_fraud?).to be(true)
          seller.mark_compliant!(author_id: reviewer.id)
        end

        it "keeps the reviewer's compliant verdict on the next sale" do
          build_checkout_purchase(seller).save!

          seller.reload
          expect(seller.compliant?).to be(true)
          expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
        end

        it "does not re-pause or re-flag on the next sale when the reviewer also resumed payouts" do
          seller.update!(payouts_paused_internally: false, payouts_paused_by: nil)
          seller.comments.create!(
            author_id: reviewer.id,
            comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED,
            content: "Payouts resumed."
          )

          build_checkout_purchase(seller).save!

          seller.reload
          expect(seller.compliant?).to be(true)
          expect(seller.payouts_paused_internally?).to be(false)
          expect(
            seller.comments.with_type_on_probation
                  .where(author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:chargeback_ring_signal])
          ).to be_empty
        end
      end

      # The other half of the same guard: a LATER AUTOMATIC hold replacing the ring's as the
      # newest pausing comment is not a human decision, so the ring must re-record its hold over
      # it — otherwise the rate-recovery release could lift it and pay a ring seller out.
      it "re-records the ring hold when a later automatic hold replaced it as the newest" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        allow(ErrorNotifier).to receive(:notify)
        build_checkout_purchase(seller).save!
        expect(seller.reload.payouts_paused_for_chargeback_ring_signal?).to be(true)

        seller.comments.create!(
          content: "rate hold",
          comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
          author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate]
        )
        expect(seller.reload.payouts_paused_for_chargeback_ring_signal?).to be(false)

        build_checkout_purchase(seller).save!

        seller.reload
        expect(seller.payouts_paused_for_chargeback_ring_signal?).to be(true)
        expect(seller.payouts_paused_for_chargeback_rate?).to be(false)
        expect(seller.payouts_paused_internally?).to be(true)
      end

      it "pauses a verified seller's payouts without attempting the fraud flag that not_verified? would halt" do
        seller.update!(verified: true)
        seed_paid_sales(seller, count: 5)
        arm_flag
        allow(ErrorNotifier).to receive(:notify)

        build_checkout_purchase(seller).save!

        seller.reload
        expect(seller.payouts_paused_for_chargeback_ring_signal?).to be(true)
        expect(seller.flagged_for_fraud?).to be(false)
        expect(ErrorNotifier).not_to have_received(:notify).with(instance_of(StateMachines::InvalidTransition), anything)
      end

      it "leaves an admin payout pause untouched" do
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_ADMIN)
        seed_paid_sales(seller, count: 5)
        arm_flag
        allow(ErrorNotifier).to receive(:notify)

        build_checkout_purchase(seller).save!
        expect(seller.reload.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
      end

      it "still pauses payouts when the telemetry insert fails (containment does not depend on telemetry)" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        allow(ErrorNotifier).to receive(:notify)
        allow(ChargebackRingSignal).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")

        build_checkout_purchase(seller).save!

        seller.reload
        expect(seller.payouts_paused_for_chargeback_ring_signal?).to be(true)
        expect(ErrorNotifier).to have_received(:notify).with(instance_of(ActiveRecord::StatementInvalid), anything).at_least(:once)
      end

      it "still records telemetry when containment fails" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        allow(ErrorNotifier).to receive(:notify)
        allow_any_instance_of(User).to receive(:with_lock).and_raise(ActiveRecord::LockWaitTimeout)

        purchase = build_checkout_purchase(seller)
        expect { purchase.save! }.to change { ChargebackRingSignal.where(decision: "blocked").count }.by(1)
        expect(purchase.errors).to be_empty
      end

      it "fails open on an evaluation exception: the purchase is allowed and an error row is written" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        purchase = build_checkout_purchase(seller)

        allow(described_class).to receive(:evaluate).and_raise(Timeout::Error)
        allow(ErrorNotifier).to receive(:notify)

        expect { purchase.save! }.to change { ChargebackRingSignal.where(decision: "error").count }.by(1)
        expect(purchase.errors).to be_empty
        expect(purchase.error_code).to be_nil
        expect(seller.reload.payouts_paused_internally?).to be(false)
      end

      it "survives ErrorNotifier itself raising" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        allow(described_class).to receive(:evaluate).and_raise(Timeout::Error)
        allow(ErrorNotifier).to receive(:notify).and_raise(StandardError, "notifier down")

        purchase = build_checkout_purchase(seller)
        expect { purchase.save! }.not_to raise_error
        expect(purchase.errors).to be_empty
      end

      it "allows a young legitimate seller with one-country buyers on residential IPs: no refusal, no pause, no flag" do
        seed_paid_sales(seller, count: 5, hosting: false)
        arm_flag
        purchase = build_checkout_purchase(seller, ip_address: "88.12.99.99")

        expect { purchase.save! }.to change { ChargebackRingSignal.count }.by(1)
        expect(purchase.errors).to be_empty

        row = ChargebackRingSignal.last
        expect(row.decision).to eq("allowed")
        expect(row.hosting_share_pct).to eq(0.0)
        seller.reload
        expect(seller.payouts_paused_internally?).to be(false)
        expect(seller.flagged_for_fraud?).to be(false)
      end

      it "skips recurring subscription charges" do
        seed_paid_sales(seller, count: 5)
        arm_flag
        purchase = build_checkout_purchase(seller)
        allow(purchase).to receive(:is_recurring_subscription_charge).and_return(true)

        expect(described_class).not_to receive(:evaluate)
        purchase.send(:evaluate_chargeback_ring_signal)
        expect(purchase.errors).to be_empty
      end

      it "writes no telemetry row below the volume floor" do
        seed_paid_sales(seller, count: 1)
        arm_flag
        purchase = build_checkout_purchase(seller)

        expect { purchase.save! }.not_to change { ChargebackRingSignal.count }
        expect(purchase.errors).to be_empty
      end
    end

    context "when chargeback_ring_signal_enforce is also on" do
      let(:seller) { create(:user, created_at: 10.days.ago) }

      def arm_flags
        Feature.activate_user(described_class::FEATURE_FLAG, seller)
        Feature.activate_user(described_class::ENFORCE_FLAG, seller)
      end

      def hit_result
        described_class::Result.new(
          decision: described_class::DECISION_BLOCKED,
          paid_sales: 5, dominant_card_country: "BR", dominant_share_pct: 100.0,
          hosting_share_pct: 100.0, distinct_browsers: 2, matched_cidr: "151.240.0.0/16"
        )
      end

      it "refuses the charge before the processor is called when the in-flight purchase carries the ring evidence" do
        seed_paid_sales(seller, count: 5)
        arm_flags
        purchase = build_checkout_purchase(seller, card_country: "BR", ip_address: "151.240.50.1")
        purchase.instance_variable_set(:@chargeback_ring_signal_result, hit_result)
        purchase.chargeable = instance_double(Chargeable)

        expect(purchase).not_to receive(:create_charge_intent)
        expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)

        purchase.charge!

        expect(purchase.errors[:base]).to be_present
        expect(purchase.errors.full_messages.join).not_to match(/fraud|seller|ring|block/i)
        expect(purchase.error_code).to eq(PurchaseErrorCode::CHARGEBACK_RING_SIGNAL)
        expect(purchase.charge_intent).to be_nil
      end

      it "does not refuse a buyer on a residential IP even when the seller is a hit" do
        seed_paid_sales(seller, count: 5)
        arm_flags
        purchase = build_checkout_purchase(seller, card_country: "BR", ip_address: "88.12.99.99")
        purchase.instance_variable_set(:@chargeback_ring_signal_result, hit_result)

        expect(purchase.send(:refuse_charge_for_chargeback_ring_signal?)).to be(false)
        expect(purchase.errors).to be_empty
      end

      it "does not refuse a buyer whose card country is not the dominant one" do
        seed_paid_sales(seller, count: 5)
        arm_flags
        purchase = build_checkout_purchase(seller, card_country: "US", ip_address: "151.240.50.1")
        purchase.instance_variable_set(:@chargeback_ring_signal_result, hit_result)

        expect(purchase.send(:refuse_charge_for_chargeback_ring_signal?)).to be(false)
        expect(purchase.errors).to be_empty
      end

      it "does not refuse without the enforce flag even on full buyer-level evidence" do
        seed_paid_sales(seller, count: 5)
        Feature.activate_user(described_class::FEATURE_FLAG, seller)
        purchase = build_checkout_purchase(seller, card_country: "BR", ip_address: "151.240.50.1")
        purchase.instance_variable_set(:@chargeback_ring_signal_result, hit_result)

        expect(purchase.send(:refuse_charge_for_chargeback_ring_signal?)).to be(false)
        expect(purchase.errors).to be_empty
      end

      it "fails open and restores error_code when the refusal check itself raises" do
        seed_paid_sales(seller, count: 5)
        arm_flags
        purchase = build_checkout_purchase(seller, card_country: "BR", ip_address: "151.240.50.1")
        purchase.instance_variable_set(:@chargeback_ring_signal_result, hit_result)
        allow(ErrorNotifier).to receive(:notify)
        # Raise after the refusal state was assigned: vague_error_message runs post-assignment.
        allow(purchase).to receive(:vague_error_message).and_raise(StandardError, "boom")

        expect(purchase.send(:refuse_charge_for_chargeback_ring_signal?)).to be(false)
        expect(purchase.errors).to be_empty
        expect(purchase.error_code).to be_nil
      end

      it "refuses a combined (cart) charge before the processor is called" do
        seed_paid_sales(seller, count: 5)
        arm_flags
        purchase = build_checkout_purchase(seller, card_country: "BR", ip_address: "151.240.50.1")
        purchase.instance_variable_set(:@chargeback_ring_signal_result, hit_result)
        purchase.save(validate: false)
        order = create(:order)

        expect(ChargeProcessor).not_to receive(:create_payment_intent_or_charge!)

        charge = Charge::CreateService.new(
          order:, seller:, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
          chargeable: instance_double(Chargeable, fingerprint: "fp", charge_processor_id: "stripe"),
          purchases: [purchase], amount_cents: 2200, gumroad_amount_cents: 220,
          setup_future_charges: false, off_session: false, statement_description: nil,
          mandate_options: nil, params: {}
        ).perform

        expect(charge.charge_intent).to be_nil
        expect(purchase.error_code).to eq(PurchaseErrorCode::CHARGEBACK_RING_SIGNAL)
        expect(purchase.errors[:base]).to be_present
      end

      context "with a purchase loaded in a later request (no checkout-time verdict)" do
        def reloaded_ring_purchase
          # Saved before the flags are armed, so before_create never stored a verdict.
          purchase = build_checkout_purchase(seller, card_country: "BR", ip_address: "151.240.50.1")
          purchase.save!
          Purchase.find(purchase.id)
        end

        before do
          seed_paid_sales(seller, count: 5)
          allow(ErrorNotifier).to receive(:notify)
        end

        def ring_signal_rows(purchase) = ChargebackRingSignal.where(purchase_id: purchase.id).pluck(:decision)

        it "evaluates on first read and refuses the charge" do
          purchase = reloaded_ring_purchase
          arm_flags

          expect(purchase.refuse_charge_for_chargeback_ring_signal?).to be(true)
          expect(purchase.error_code).to eq(PurchaseErrorCode::CHARGEBACK_RING_SIGNAL)
        end

        # Its create commit has already passed, so the lazy hit needs its own recording.
        it "records the lazy hit and contains the seller once, however often it is read" do
          purchase = reloaded_ring_purchase
          arm_flags

          2.times { purchase.refuse_charge_for_chargeback_ring_signal? }

          expect(ring_signal_rows(purchase)).to eq(["blocked"])
          seller.reload
          expect(seller.payouts_paused_for_chargeback_ring_signal?).to be(true)
          expect(seller.flagged_for_fraud?).to be(true)
          expect(ErrorNotifier).to have_received(:notify).with(a_string_including("chargeback_ring_signal hit")).once
        end

        it "records and contains for a buyer it does not refuse" do
          purchase = build_checkout_purchase(seller, card_country: "BR", ip_address: "88.12.99.99")
          purchase.save!
          purchase = Purchase.find(purchase.id)
          arm_flags

          expect(purchase.refuse_charge_for_chargeback_ring_signal?).to be(false)
          expect(ring_signal_rows(purchase)).to eq(["blocked"])
          expect(seller.reload.payouts_paused_for_chargeback_ring_signal?).to be(true)
        end

        it "records nothing until the surrounding transaction commits, and nothing if it rolls back" do
          committed = reloaded_ring_purchase
          rolled_back = reloaded_ring_purchase
          arm_flags

          ActiveRecord::Base.transaction do
            committed.refuse_charge_for_chargeback_ring_signal?
            expect(ring_signal_rows(committed)).to be_empty
            expect(seller.reload.payouts_paused_internally?).to be(false)
          end
          expect(ring_signal_rows(committed)).to eq(["blocked"])

          ActiveRecord::Base.transaction do
            rolled_back.refuse_charge_for_chargeback_ring_signal?
            raise ActiveRecord::Rollback
          end
          expect(ring_signal_rows(rolled_back)).to be_empty
        end

        it "records once when the lazy read happens before the purchase's own create commit" do
          purchase = build_checkout_purchase(seller, card_country: "BR", ip_address: "151.240.50.1")

          ActiveRecord::Base.transaction do
            purchase.save!
            arm_flags
            purchase.refuse_charge_for_chargeback_ring_signal?
          end

          expect(ring_signal_rows(purchase)).to eq(["blocked"])
        end

        it "keeps a human's release when a later resumed charge is refused" do
          pending_purchase = reloaded_ring_purchase
          arm_flags
          build_checkout_purchase(seller, card_country: "US", ip_address: "88.12.1.1").save!
          expect(seller.reload.payouts_paused_for_chargeback_ring_signal?).to be(true)
          reviewer = create(:user)
          seller.update!(payouts_paused_internally: false, payouts_paused_by: nil)
          seller.comments.create!(author_id: reviewer.id, comment_type: Comment::COMMENT_TYPE_PAYOUTS_RESUMED, content: "Payouts resumed.")
          seller.mark_compliant!(author_id: reviewer.id)

          resumed = Purchase.find(pending_purchase.id)

          expect(resumed.refuse_charge_for_chargeback_ring_signal?).to be(true)
          expect(ring_signal_rows(resumed)).to eq(["blocked"])
          seller.reload
          expect(seller.payouts_paused_internally?).to be(false)
          expect(seller.compliant?).to be(true)
        end

        it "memoizes the verdict per purchase and shares the per-seller cache across purchases" do
          first = reloaded_ring_purchase
          second = reloaded_ring_purchase
          arm_flags

          expect(described_class).to receive(:evaluate).twice.and_call_original
          expect(described_class).to receive(:evaluate_uncached).once.and_call_original
          first.refuse_charge_for_chargeback_ring_signal?
          first.refuse_charge_for_chargeback_ring_signal?
          second.refuse_charge_for_chargeback_ring_signal?
        end

        it "does not evaluate when only the shadow flag is on" do
          purchase = reloaded_ring_purchase
          Feature.activate_user(described_class::FEATURE_FLAG, seller)

          expect(described_class).not_to receive(:evaluate)
          expect(purchase.refuse_charge_for_chargeback_ring_signal?).to be(false)
          expect(ring_signal_rows(purchase)).to be_empty
        end

        it "does not evaluate a recurring subscription charge" do
          purchase = reloaded_ring_purchase
          arm_flags
          allow(purchase).to receive(:is_recurring_subscription_charge).and_return(true)

          expect(described_class).not_to receive(:evaluate)
          expect(purchase.refuse_charge_for_chargeback_ring_signal?).to be(false)
          expect(ring_signal_rows(purchase)).to be_empty
        end

        it "fails open when the lazy evaluation raises, and records an error row" do
          purchase = reloaded_ring_purchase
          arm_flags
          allow(described_class).to receive(:evaluate).and_raise(Timeout::Error)

          expect(purchase.refuse_charge_for_chargeback_ring_signal?).to be(false)
          expect(purchase.errors).to be_empty
          expect(purchase.error_code).to be_nil
          expect(ring_signal_rows(purchase)).to eq(["error"])
          expect(seller.reload.payouts_paused_internally?).to be(false)
        end
      end

      # The suspension lands AFTER the pause step and through a SECOND object, so the copy the
      # purchase holds is still stale exactly when the flag step reads the account's state. The
      # example fails if that read is not taken again under the lock: a stale copy reports
      # `can_flag_for_fraud?`, so the ring flag would overwrite the suspension.
      it "does not flag a seller who was suspended concurrently (state re-checked under the lock)" do
        seed_paid_sales(seller, count: 5)
        arm_flags
        allow(ErrorNotifier).to receive(:notify)
        allow_any_instance_of(Purchase).to receive(:pause_seller_payouts_for_ring_signal!).and_wrap_original do |original, *args|
          original.call(*args)
          User.find(seller.id).suspend_for_fraud!(author_name: "test")
        end

        build_checkout_purchase(seller, card_country: "US", ip_address: "88.12.1.1").save!

        expect(seller.reload.suspended_for_fraud?).to be(true)
      end

      it "leaves the refusal on the purchase's errors, which Purchase::CreateService turns into PurchaseInvalid" do
        seed_paid_sales(seller, count: 5)
        arm_flags
        purchase = build_checkout_purchase(seller, card_country: "BR", ip_address: "151.240.50.1")
        purchase.instance_variable_set(:@chargeback_ring_signal_result, hit_result)
        purchase.chargeable = instance_double(Chargeable)
        purchase.charge!

        # CreateService raises Purchase::PurchaseInvalid whenever charge! leaves errors, and its
        # rescue path runs handle_purchase_failure — the same rollback every refused charge takes.
        expect(purchase.errors).to be_present
      end
    end
  end
end
