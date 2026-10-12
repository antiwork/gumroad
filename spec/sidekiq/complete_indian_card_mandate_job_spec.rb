# frozen_string_literal: true

require "spec_helper"

describe CompleteIndianCardMandateJob do
  let(:seller) { create(:user) }
  let(:buyer) { create(:user) }
  let(:product) { create(:subscription_product_with_versions, user: seller) }
  let(:merchant_account) do
    create(:merchant_account, user: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id, charge_processor_merchant_id: nil)
  end
  let(:credit_card) do
    CreditCard.create!(
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      stripe_customer_id: "cus_pending",
      processor_payment_method_id: "pm_pending",
      stripe_fingerprint: "fingerprint_pending",
      visual: "**** **** **** 4242",
      card_type: CardType::VISA,
      card_country: Compliance::Countries::IND.alpha2,
      expiry_month: 12,
      expiry_year: 2030
    )
  end
  let(:mandate_status) { "pending" }
  let!(:subscription) do
    subscription = create(:subscription, link: product, user: buyer, credit_card:, stripe_mandate_id: "mandate_pending")
    travel_to(2.months.ago) do
      create(:purchase,
             is_original_subscription_purchase: true,
             link: product,
             subscription:,
             purchaser: buyer,
             price_cents: product.default_price_cents,
             credit_card:,
             variant_attributes: [product.variants.first])
    end
    subscription.update!(cancelled_at: 1.day.ago, cancelled_by_buyer: true, deactivated_at: 1.day.ago)
    subscription.update!(renewal_disabled_due_to_indian_card_mandate: true)
    subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)
    subscription
  end

  before do
    allow(MerchantAccount).to receive(:gumroad).with(StripeChargeProcessor.charge_processor_id).and_return(merchant_account)
    Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
    allow(ChargeProcessor).to receive(:get_mandate) do
      Stripe::Mandate.construct_from(id: "mandate_pending", status: mandate_status, payment_method: "pm_pending")
    end
    allow_any_instance_of(Subscription).to receive(:send_restart_notifications!)
  end

  after do
    Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller)
  end

  def have_enqueued_restart_abandoned_mail
    have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid).with(subscription.id, true)
  end

  it "is configured for the low queue with a unique lock" do
    expect(described_class.sidekiq_options["queue"]).to eq(:low)
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
  end

  context "when the mandate is still pending" do
    it "keeps the membership ended and uncharged and checks again after the first delay" do
      described_class.new.perform(subscription.id)

      expect(subscription.reload).not_to be_alive
      expect(subscription).to be_indian_card_mandate_restart_held
      expect(subscription).to be_renewal_disabled_due_to_indian_card_mandate
      expect(RecurringChargeWorker.jobs.size).to eq(0)
      expect(described_class.jobs.map { _1["args"] }).to eq([[subscription.id, 1, nil]])
    end

    it "carries the chain's generation into each recheck" do
      generation = described_class.next_generation(subscription.id)

      described_class.new.perform(subscription.id, 0, generation)

      expect(described_class.jobs.map { _1["args"] }).to eq([[subscription.id, 1, generation]])
    end

    it "stops waiting after the last delay, leaves the membership ended, and tells the buyer once" do
      expect do
        described_class.new.perform(subscription.id, CheckIndianCardMandateRegistrationJob::PENDING_RECHECK_DELAYS.length)
      end.to have_enqueued_restart_abandoned_mail.once

      expect(subscription.reload).not_to be_alive
      expect(subscription).not_to be_indian_card_mandate_restart_held
      expect(described_class.jobs).to be_empty
    end
  end

  context "when the mandate has become active" do
    let(:mandate_status) { "active" }

    it "restarts the membership, notifies, and queues the overdue charge" do
      expect_any_instance_of(Subscription).to receive(:send_restart_notifications!).once

      described_class.new.perform(subscription.id)

      expect(subscription.reload).to be_alive
      expect(subscription).not_to be_indian_card_mandate_restart_held
      expect(subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
      expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[subscription.id]])
    end

    context "when the membership was still pending cancellation at the submission" do
      before { subscription.update!(cancelled_at: 5.days.from_now, deactivated_at: nil) }

      it "cancels the pending cancellation through the restart, notifies, and queues the overdue charge" do
        expect_any_instance_of(Subscription).to receive(:send_restart_notifications!).once
        expect(subscription.reload.pending_cancellation?).to be(true)

        expect { described_class.new.perform(subscription.id) }.not_to have_enqueued_restart_abandoned_mail

        expect(subscription.reload).to be_alive
        expect(subscription.cancelled_at).to be_nil
        expect(subscription).not_to be_cancelled_by_buyer
        expect(subscription).not_to be_indian_card_mandate_restart_held
        expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[subscription.id]])
      end

      it "does not charge while the mandate is still pending and leaves the cancellation in place" do
        allow(ChargeProcessor).to receive(:get_mandate).and_return(
          Stripe::Mandate.construct_from(id: "mandate_pending", status: "pending", payment_method: "pm_pending")
        )

        described_class.new.perform(subscription.id)

        expect(subscription.reload.pending_cancellation?).to be(true)
        expect(subscription).to be_indian_card_mandate_restart_held
        expect(RecurringChargeWorker.jobs).to be_empty
      end

      it "leaves the pending cancellation in place and releases the hold when the seller has been suspended meanwhile" do
        allow_any_instance_of(User).to receive(:suspended?).and_return(true)
        expect_any_instance_of(Subscription).not_to receive(:send_restart_notifications!)

        expect { described_class.new.perform(subscription.id) }.to have_enqueued_restart_abandoned_mail.once

        expect(subscription.reload.pending_cancellation?).to be(true)
        expect(subscription).not_to be_indian_card_mandate_restart_held
        expect(RecurringChargeWorker.jobs).to be_empty
      end

      it "leaves an admin cancellation made after the submission in place" do
        subscription.update!(cancelled_by_admin: true)

        expect { described_class.new.perform(subscription.id) }.to have_enqueued_restart_abandoned_mail.once

        expect(subscription.reload).to be_cancelled_by_admin
        expect(subscription.cancelled_at).to be_present
        expect(subscription).not_to be_indian_card_mandate_restart_held
        expect(RecurringChargeWorker.jobs).to be_empty
      end
    end

    it "finishes the restart on a retry after the restart failed once the refresh had cleared the renewal stop" do
      allow_any_instance_of(Subscription).to receive(:resubscribe!).and_raise(ActiveRecord::StatementInvalid, "lock wait timeout")

      expect { described_class.new.perform(subscription.id) }.to raise_error(ActiveRecord::StatementInvalid)

      expect(subscription.reload).not_to be_alive
      expect(subscription).to be_indian_card_mandate_restart_held
      expect(subscription).not_to be_renewal_disabled_due_to_indian_card_mandate
      expect(RecurringChargeWorker.jobs.size).to eq(0)

      allow_any_instance_of(Subscription).to receive(:resubscribe!).and_call_original
      expect_any_instance_of(Subscription).to receive(:send_restart_notifications!).once

      described_class.new.perform(subscription.id)

      expect(subscription.reload).to be_alive
      expect(subscription).not_to be_indian_card_mandate_restart_held
      expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[subscription.id]])
    end

    it "does nothing a second time" do
      2.times { described_class.new.perform(subscription.id) }

      expect(RecurringChargeWorker.jobs.size).to eq(1)
    end

    it "leaves no recovery marker once the overdue charge is queued" do
      described_class.new.perform(subscription.id)

      expect(subscription.reload).not_to be_indian_card_mandate_recovery_pending
    end

    describe "when queuing the overdue charge fails after the restart committed" do
      def fail_enqueue_once
        calls = 0
        allow(RecurringChargeWorker).to receive(:perform_async).and_wrap_original do |original, *args|
          calls += 1
          raise Redis::CannotConnectError, "redis down" if calls == 1

          original.call(*args)
        end
      end

      it "keeps a durable marker and queues the charge exactly once on the retry" do
        fail_enqueue_once

        expect { described_class.new.perform(subscription.id) }.to raise_error(Redis::CannotConnectError)

        expect(subscription.reload).to be_alive
        expect(subscription).not_to be_indian_card_mandate_restart_held
        expect(subscription).to be_indian_card_mandate_recovery_pending
        expect(RecurringChargeWorker.jobs).to be_empty

        described_class.new.perform(subscription.id)

        expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[subscription.id]])
        expect(subscription.reload).not_to be_indian_card_mandate_recovery_pending

        described_class.new.perform(subscription.id)

        expect(RecurringChargeWorker.jobs.size).to eq(1)
      end

      it "does not send the restart notifications a second time on the retry" do
        fail_enqueue_once
        expect_any_instance_of(Subscription).to receive(:send_restart_notifications!).once

        expect { described_class.new.perform(subscription.id) }.to raise_error(Redis::CannotConnectError)
        described_class.new.perform(subscription.id)
      end

      it "still queues the charge on the retry after a newer submission superseded the chain" do
        generation = described_class.next_generation(subscription.id)
        fail_enqueue_once

        expect { described_class.new.perform(subscription.id, 0, generation) }.to raise_error(Redis::CannotConnectError)
        described_class.next_generation(subscription.id)
        described_class.new.perform(subscription.id, 0, generation)

        expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[subscription.id]])
        expect(subscription.reload).not_to be_indian_card_mandate_recovery_pending
      end

      it "does not charge on the retry when the restarted membership has ended again" do
        fail_enqueue_once
        expect { described_class.new.perform(subscription.id) }.to raise_error(Redis::CannotConnectError)

        subscription.update!(ended_at: Time.current)
        described_class.new.perform(subscription.id)

        expect(RecurringChargeWorker.jobs).to be_empty
        expect(subscription.reload).not_to be_indian_card_mandate_recovery_pending
      end
    end

    describe "when the restart notifications fail" do
      before do
        allow_any_instance_of(Subscription).to receive(:send_restart_notifications!).and_raise(Redis::CannotConnectError, "redis down")
      end

      it "reports the failure and still queues the overdue charge without a retry" do
        expect(ErrorNotifier).to receive(:notify).with(instance_of(Redis::CannotConnectError), subscription: subscription.external_id)

        expect { described_class.new.perform(subscription.id) }.not_to raise_error

        expect(subscription.reload).to be_alive
        expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[subscription.id]])
        expect(subscription).not_to be_indian_card_mandate_recovery_pending
      end

      it "keeps the marker when the charge enqueue also fails, so the retry still queues it" do
        allow(ErrorNotifier).to receive(:notify)
        allow(RecurringChargeWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError, "redis down")

        expect { described_class.new.perform(subscription.id) }.to raise_error(Redis::CannotConnectError)
        expect(subscription.reload).to be_indian_card_mandate_recovery_pending

        allow(RecurringChargeWorker).to receive(:perform_async).and_call_original
        described_class.new.perform(subscription.id)

        expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[subscription.id]])
      end
    end
  end

  context "when the restart is no longer eligible" do
    let(:mandate_status) { "active" }

    def expect_marker_released_without_restart
      expect_any_instance_of(Subscription).not_to receive(:send_restart_notifications!)

      expect { described_class.new.perform(subscription.id) }.to have_enqueued_restart_abandoned_mail.once

      expect(subscription.reload).not_to be_alive
      expect(subscription).not_to be_indian_card_mandate_restart_held
      expect(RecurringChargeWorker.jobs).to be_empty
      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "releases the marker when the seller has been suspended" do
      allow_any_instance_of(User).to receive(:suspended?).and_return(true)

      expect_marker_released_without_restart
    end

    it "releases the marker when the product has been deleted" do
      product.mark_deleted!

      expect_marker_released_without_restart
    end

    it "releases the marker when the tier has since closed to new buyers" do
      allow_any_instance_of(Variant).to receive(:closed_to_new_buyers?).and_return(true)

      expect_marker_released_without_restart
    end

    it "releases the marker when the card is no longer supported by the creator" do
      allow_any_instance_of(User).to receive(:supports_card?).and_return(false)

      expect_marker_released_without_restart
    end

    it "releases the marker when the tier price changed after the submission" do
      allow_any_instance_of(Subscription).to receive(:tier_price_changed?).and_return(true)

      expect_marker_released_without_restart
    end

    context "when the terms the buyer accepted no longer apply" do
      before { allow_any_instance_of(Subscription).to receive(:tier_price_changed?).and_return(false) }

      it "releases the marker without a restart or charge when the subscription price has drifted" do
        purchase = subscription.original_purchase
        purchase.update_columns(displayed_price_cents: purchase.displayed_price_cents + 1_00)

        expect_marker_released_without_restart
      end

      it "releases the marker without a restart or charge when the quantity has changed" do
        subscription.original_purchase.update_columns(quantity: 2)

        expect_marker_released_without_restart
      end

      it "releases the marker without a restart or charge when the hold recorded no terms" do
        subscription.update!(indian_card_mandate_restart_price_cents: nil, indian_card_mandate_restart_quantity: nil)

        expect_marker_released_without_restart
      end

      it "restarts when the price and quantity are still the accepted ones" do
        described_class.new.perform(subscription.id)

        expect(subscription.reload).to be_alive
      end
    end

    it "keeps an admin cancellation made after the submission and sends no restart effects" do
      subscription.update!(cancelled_by_admin: true)

      expect_marker_released_without_restart
      expect(subscription).to be_cancelled_by_admin
      expect(subscription.deactivated_at).to be_present
    end

    it "leaves an ended subscription ended and sends no restart effects" do
      ended_at = 1.hour.ago.change(usec: 0)
      subscription.update!(ended_at:)

      expect_marker_released_without_restart
      expect(subscription.ended_at).to eq(ended_at)
    end

    it "releases the marker for a test subscription" do
      subscription.update!(is_test_subscription: true)

      expect_marker_released_without_restart
    end

    it "releases the marker when the product no longer bills recurringly" do
      allow_any_instance_of(Link).to receive(:is_recurring_billing).and_return(false)

      expect_marker_released_without_restart
    end

    it "agrees with the restart-at-checkout scope on every exclusion it covers" do
      expect(Subscription.restartable_for_product_and_buyer(product:, buyer:)).to eq(subscription)
      expect(subscription).to be_indian_card_mandate_restart_eligible

      { cancelled_by_admin: true, ended_at: Time.current, is_test_subscription: true }.each do |attribute, value|
        subscription.update!(attribute => value)

        expect(Subscription.restartable_for_product_and_buyer(product:, buyer:)).to be_nil
        expect(subscription).not_to be_indian_card_mandate_restart_eligible
        subscription.update!(attribute => attribute == :ended_at ? nil : false)
      end
    end
  end

  %w[inactive missing].each do |status|
    context "when the mandate is #{status}" do
      let(:mandate_status) { status }

      it "gives up without restarting or charging and tells the buyer once" do
        expect { described_class.new.perform(subscription.id) }.to have_enqueued_restart_abandoned_mail.once

        expect(subscription.reload).not_to be_alive
        expect(subscription).not_to be_indian_card_mandate_restart_held
        expect(RecurringChargeWorker.jobs.size).to eq(0)
        expect(described_class.jobs).to be_empty
      end
    end
  end

  it "ignores a membership that is not waiting on a pending restart" do
    subscription.update!(indian_card_mandate_restart_held: false)
    expect(ChargeProcessor).not_to receive(:get_mandate)

    described_class.new.perform(subscription.id)

    expect(subscription.reload).not_to be_alive
  end

  it "ignores a membership that has already been restarted" do
    subscription.resubscribe!
    subscription.update!(renewal_disabled_due_to_indian_card_mandate: false)
    expect(ChargeProcessor).not_to receive(:get_mandate)

    described_class.new.perform(subscription.id)

    expect(RecurringChargeWorker.jobs.size).to eq(0)
  end

  describe "repeat submissions" do
    let(:last_recheck) { CheckIndianCardMandateRegistrationJob::PENDING_RECHECK_DELAYS.length }

    it "ends an older submission's chain without releasing the marker the newer submission owns" do
      older = described_class.next_generation(subscription.id)
      described_class.next_generation(subscription.id)
      expect(ChargeProcessor).not_to receive(:get_mandate)

      expect do
        described_class.new.perform(subscription.id, last_recheck, older)
      end.not_to have_enqueued_restart_abandoned_mail

      expect(subscription.reload).to be_indian_card_mandate_restart_held
      expect(described_class.jobs).to be_empty
    end

    it "still restarts from the newer chain after the older chain has run out" do
      older = described_class.next_generation(subscription.id)
      described_class.new.perform(subscription.id, 0, older)
      newer = described_class.next_generation(subscription.id)
      described_class.new.perform(subscription.id, last_recheck, older)

      expect(subscription.reload).to be_indian_card_mandate_restart_held

      allow(ChargeProcessor).to receive(:get_mandate).and_return(
        Stripe::Mandate.construct_from(id: "mandate_pending", status: "active", payment_method: "pm_pending")
      )
      described_class.new.perform(subscription.id, 0, newer)

      expect(subscription.reload).to be_alive
      expect(subscription).not_to be_indian_card_mandate_restart_held
    end

    it "does not release when a newer submission claims the marker between the older chain's check and its release" do
      older = described_class.next_generation(subscription.id)
      allow_any_instance_of(Subscription).to receive(:refresh_indian_card_mandate!) do
        described_class.next_generation(subscription.id)
        "pending"
      end

      expect do
        described_class.new.perform(subscription.id, last_recheck, older)
      end.not_to have_enqueued_restart_abandoned_mail

      expect(subscription.reload).to be_indian_card_mandate_restart_held
    end

    it "releases the marker and tells the buyer when the newest chain runs out" do
      generation = described_class.next_generation(subscription.id)

      expect do
        described_class.new.perform(subscription.id, last_recheck, generation)
      end.to have_enqueued_restart_abandoned_mail.once

      expect(subscription.reload).not_to be_indian_card_mandate_restart_held
    end

    it "tells the buyer only once when the chain end and an exhausted retry both release the same hold" do
      generation = described_class.next_generation(subscription.id)
      msg = { "class" => described_class.name, "args" => [subscription.id, 0, generation] }

      expect do
        described_class.new.perform(subscription.id, last_recheck, generation)
        described_class.release(subscription, generation)
        described_class.sidekiq_retries_exhausted_block.call(msg, ChargeProcessorError.new("stripe down"))
      end.to have_enqueued_restart_abandoned_mail.once
    end

    it "tells the buyer again for a later hold on the same membership" do
      first = described_class.next_generation(subscription.id)
      expect { described_class.release(subscription, first) }.to have_enqueued_restart_abandoned_mail.once

      subscription.hold_indian_card_mandate_restart!(authenticated_offer_code_buyer: buyer)
      second = described_class.next_generation(subscription.id)

      expect { described_class.release(subscription, second) }.to have_enqueued_restart_abandoned_mail.once
    end

    it "does not send the mail when the release transaction rolls back" do
      expect do
        subscription.with_lock do
          described_class.abandon_restart(subscription)
          raise ActiveRecord::Rollback
        end
      end.not_to have_enqueued_restart_abandoned_mail

      expect(subscription.reload).to be_indian_card_mandate_restart_held
    end

    it "reports a failed mail enqueue without failing the release" do
      generation = described_class.next_generation(subscription.id)
      allow(CustomerLowPriorityMailer).to receive(:subscription_indian_card_mandate_invalid).and_raise(Redis::CannotConnectError)
      expect(ErrorNotifier).to receive(:notify).with(instance_of(Redis::CannotConnectError), subscription: subscription.external_id)

      expect { described_class.release(subscription, generation) }.not_to raise_error

      expect(subscription.reload).not_to be_indian_card_mandate_restart_held
    end

    it "schedules a fresh generation for every submission" do
      first = described_class.schedule(subscription.id)
      second = described_class.schedule(subscription.id)

      expect(first).not_to eq(second)
      generations = described_class.jobs.map { _1["args"].last }
      expect(generations).to eq(generations.sort)
      expect(generations.uniq.size).to eq(2)
      expect(described_class.superseded?(subscription.id, generations.first)).to be(true)
      expect(described_class.superseded?(subscription.id, generations.last)).to be(false)
    end
  end

  describe "when the chain cannot finish" do
    it "releases the held restart's marker and tells the buyer once the retries are exhausted" do
      generation = described_class.next_generation(subscription.id)
      msg = { "class" => described_class.name, "args" => [subscription.id, 0, generation] }

      expect do
        described_class.sidekiq_retries_exhausted_block.call(msg, ChargeProcessorError.new("stripe down"))
      end.to have_enqueued_restart_abandoned_mail.once

      expect(subscription.reload).not_to be_indian_card_mandate_restart_held
      expect(subscription.reusable_pending_indian_card).to be_nil
    end

    it "leaves a newer submission's marker alone when an older chain's retries are exhausted" do
      older = described_class.next_generation(subscription.id)
      described_class.next_generation(subscription.id)
      msg = { "class" => described_class.name, "args" => [subscription.id, 0, older] }

      expect do
        described_class.sidekiq_retries_exhausted_block.call(msg, ChargeProcessorError.new("stripe down"))
      end.not_to have_enqueued_restart_abandoned_mail

      expect(subscription.reload).to be_indian_card_mandate_restart_held
    end

    it "leaves a membership that is not a held restart untouched when its retries are exhausted" do
      subscription.update!(indian_card_mandate_restart_held: false)
      msg = { "class" => described_class.name, "args" => [subscription.id, 0, nil] }

      expect do
        expect do
          described_class.sidekiq_retries_exhausted_block.call(msg, ChargeProcessorError.new("stripe down"))
        end.not_to change { subscription.reload.attributes }
      end.not_to have_enqueued_restart_abandoned_mail
    end

    it "retries a provider error before giving up, keeping the marker while retries remain" do
      allow(ChargeProcessor).to receive(:get_mandate).and_raise(ChargeProcessorError, "stripe down")

      expect { described_class.new.perform(subscription.id) }.to raise_error(ChargeProcessorError)

      expect(subscription.reload).to be_indian_card_mandate_restart_held
    end
  end

  describe ".claim_held_restart" do
    let(:generation_key) { RedisKey.indian_card_mandate_completion_generation(subscription.id) }
    let!(:earlier_generation) { described_class.next_generation(subscription.id) }
    let(:unchanged_payment_method) { [subscription.stripe_mandate_id, subscription.credit_card_id] }
    let(:changed_payment_method) { [nil, nil] }
    let(:active_mandate) { Stripe::Mandate.construct_from(id: "mandate_pending", status: "active", payment_method: "pm_pending") }

    def claim(payment_method_before)
      Subscription.transaction do
        described_class.claim_held_restart(subscription, authenticated_offer_code_buyer: buyer, payment_method_before:)
      end
    end

    it "claims nothing for a repeat submission that changes neither the payment method nor the accepted terms" do
      expect(claim(unchanged_payment_method)).to be_nil

      expect($redis.get(generation_key).to_i).to eq(earlier_generation)
      expect(subscription.reload).to be_indian_card_mandate_restart_held
      expect(described_class.superseded?(subscription.id, earlier_generation)).to be(false)
    end

    it "lets the earlier chain complete the restart after a repeat submission that claimed nothing" do
      claim(unchanged_payment_method)
      allow(ChargeProcessor).to receive(:get_mandate).and_return(active_mandate)

      described_class.new.perform(subscription.id, 0, earlier_generation)

      expect(subscription.reload).to be_alive
      expect(subscription).not_to be_indian_card_mandate_restart_held
    end

    it "claims a new generation when the submission changes the payment method" do
      result = claim(changed_payment_method)

      expect(result.generation).to eq(earlier_generation + 1)
      expect(result.replaced_hold).to be(true)
    end

    it "claims a new generation when the accepted terms changed" do
      subscription.update!(indian_card_mandate_restart_price_cents: subscription.indian_card_mandate_restart_price_cents + 1)

      expect(claim(unchanged_payment_method).generation).to eq(earlier_generation + 1)
    end

    it "claims a new generation when no earlier chain is recorded" do
      $redis.del(generation_key)

      result = claim(unchanged_payment_method)

      expect(result.generation).to eq(1)
      expect(result.replaced_hold).to be(true)
    end

    it "reports a first hold as not replacing one" do
      subscription.update!(indian_card_mandate_restart_held: false)

      expect(claim(unchanged_payment_method).replaced_hold).to be(false)
    end

    context "when the claiming transaction rolls back after the increment" do
      def claim_then_fail(payment_method_before = changed_payment_method)
        Subscription.transaction do
          described_class.claim_held_restart(subscription, authenticated_offer_code_buyer: buyer, payment_method_before:)
          raise "commit failed"
        end
      end

      it "restores the earlier generation so the earlier chain still completes the restart" do
        expect { claim_then_fail }.to raise_error("commit failed")

        expect($redis.get(generation_key).to_i).to eq(earlier_generation)
        expect(described_class.superseded?(subscription.id, earlier_generation)).to be(false)
        expect(subscription.reload).to be_indian_card_mandate_restart_held

        allow(ChargeProcessor).to receive(:get_mandate).and_return(active_mandate)
        described_class.new.perform(subscription.id, 0, earlier_generation)

        expect(subscription.reload).to be_alive
      end

      it "enqueues the earlier chain again in case it ended while superseded" do
        expect { claim_then_fail }.to raise_error("commit failed")

        expect(described_class.jobs.map { _1["args"] }).to eq([[subscription.id, 0, earlier_generation]])
      end

      it "leaves a newer claim's generation alone" do
        allow($redis).to receive(:incr).and_wrap_original do |original, *args|
          original.call(*args).tap { original.call(*args) }
        end

        expect do
          expect { claim_then_fail }.to raise_error("commit failed")
        end.not_to have_enqueued_restart_abandoned_mail

        expect($redis.get(generation_key).to_i).to eq(earlier_generation + 2)
        expect(described_class.jobs).to be_empty
      end

      it "tells the buyer the restart was abandoned when the earlier generation cannot be restored" do
        allow($redis).to receive(:eval).and_raise(Redis::CannotConnectError)
        expect(ErrorNotifier).to receive(:notify).with(instance_of(Redis::CannotConnectError), subscription_id: subscription.id)

        expect do
          expect { claim_then_fail }.to raise_error("commit failed")
        end.to have_enqueued_restart_abandoned_mail.once

        expect(subscription.reload).not_to be_indian_card_mandate_restart_held
      end

      it "does nothing when the increment never happened" do
        allow($redis).to receive(:incr).and_raise(Redis::CannotConnectError)

        expect do
          expect { claim_then_fail }.to raise_error(Redis::CannotConnectError)
        end.not_to have_enqueued_restart_abandoned_mail

        expect($redis.get(generation_key).to_i).to eq(earlier_generation)
        expect(subscription.reload).to be_indian_card_mandate_restart_held
        expect(described_class.jobs).to be_empty
      end
    end
  end

  describe ".release_unscheduled" do
    it "mails the buyer when the claim replaced a hold they were already promised a restart for" do
      claim = described_class::Claim.new(described_class.next_generation(subscription.id), true)

      expect { described_class.release_unscheduled(subscription, claim) }.to have_enqueued_restart_abandoned_mail.once

      expect(subscription.reload).not_to be_indian_card_mandate_restart_held
    end

    it "stays silent for a first hold, which promised nothing" do
      claim = described_class::Claim.new(described_class.next_generation(subscription.id), false)

      expect { described_class.release_unscheduled(subscription, claim) }.not_to have_enqueued_restart_abandoned_mail

      expect(subscription.reload).not_to be_indian_card_mandate_restart_held
    end
  end

  context "when an unrelated purchase for the held subscription is confirmed or fails" do
    let!(:unrelated_purchase) do
      create(:purchase_in_progress, link: product, subscription:, purchaser: buyer, credit_card:, is_original_subscription_purchase: false)
    end

    it "keeps the held restart when the purchase is confirmed" do
      allow_any_instance_of(Purchase).to receive(:confirm_charge_intent!).and_return(true)
      expect_any_instance_of(Subscription).not_to receive(:send_restart_notifications!)

      Purchase::ConfirmService.new(purchase: unrelated_purchase, params: {}).perform

      expect(subscription.reload).to be_indian_card_mandate_restart_held
      expect(subscription).to be_indian_card_mandate_restart_pending
      expect(subscription).not_to be_alive
    end

    it "keeps the held restart and the ended membership when the purchase fails" do
      expect_any_instance_of(Subscription).not_to receive(:unsubscribe_and_fail!)

      Purchase::ConfirmService.new(
        purchase: unrelated_purchase,
        params: { stripe_error: { code: "invalid_request_error", message: "We are unable to authenticate your payment method." } }
      ).perform

      expect(unrelated_purchase.reload).to be_failed
      expect(subscription.reload).to be_indian_card_mandate_restart_held
      expect(subscription).to be_indian_card_mandate_restart_pending
    end

    it "still completes the restart once the mandate is active" do
      described_class.new.perform(subscription.id)
      Purchase::ConfirmService.new(
        purchase: unrelated_purchase,
        params: { stripe_error: { code: "invalid_request_error", message: "declined" } }
      ).perform
      allow(ChargeProcessor).to receive(:get_mandate) do
        Stripe::Mandate.construct_from(id: "mandate_pending", status: "active", payment_method: "pm_pending")
      end

      described_class.new.perform(subscription.id)

      expect(subscription.reload).to be_alive
      expect(subscription).not_to be_indian_card_mandate_restart_held
    end
  end

  context "for a live membership whose replacement card's mandate was pending" do
    let(:purchased_at) { 2.months.ago }
    let!(:live_subscription) do
      live = create(:subscription, link: product, user: create(:user), credit_card:, stripe_mandate_id: "mandate_pending")
      travel_to(purchased_at) do
        create(:purchase,
               is_original_subscription_purchase: true,
               link: product,
               subscription: live,
               purchaser: live.user,
               price_cents: product.default_price_cents,
               credit_card:,
               variant_attributes: [product.variants.first])
      end
      live.update!(renewal_disabled_due_to_indian_card_mandate: true)
      live
    end

    it "keeps renewals stopped and uncharged and checks again while the mandate is pending" do
      described_class.new.perform(live_subscription.id, 0, 7)

      expect(live_subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
      expect(RecurringChargeWorker.jobs).to be_empty
      expect(described_class.jobs.map { _1["args"] }).to eq([[live_subscription.id, 1, 7]])
    end

    it "keeps the replacement card and tells the buyer to update it after the last delay" do
      expect do
        described_class.new.perform(live_subscription.id, CheckIndianCardMandateRegistrationJob::PENDING_RECHECK_DELAYS.length)
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid).with(live_subscription.id).once

      expect(live_subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
      expect(live_subscription.credit_card).to eq(credit_card)
      expect(live_subscription).not_to be_indian_card_mandate_recovery_pending
      expect(RecurringChargeWorker.jobs).to be_empty
      expect(described_class.jobs).to be_empty
    end

    %w[inactive missing].each do |status|
      it "tells the buyer to update the card and does not charge when the mandate is #{status}" do
        allow(ChargeProcessor).to receive(:get_mandate).and_return(
          Stripe::Mandate.construct_from(id: "mandate_pending", status:, payment_method: "pm_pending")
        )

        expect do
          described_class.new.perform(live_subscription.id)
        end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid).with(live_subscription.id).once

        expect(live_subscription.reload).to be_renewal_disabled_due_to_indian_card_mandate
        expect(live_subscription).not_to be_indian_card_mandate_recovery_pending
        expect(RecurringChargeWorker.jobs).to be_empty
        expect(described_class.jobs).to be_empty
      end
    end

    it "does not tell the buyer anything while the mandate is still pending and rechecks remain" do
      expect do
        described_class.new.perform(live_subscription.id)
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid)
    end

    it "does not notify when a newer submission has superseded the chain" do
      older = described_class.next_generation(live_subscription.id)
      described_class.next_generation(live_subscription.id)

      expect do
        described_class.release_recovery(live_subscription, older)
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid)
    end

    it "does not notify once the buyer has moved on to a card whose renewals are not stopped" do
      live_subscription.update!(renewal_disabled_due_to_indian_card_mandate: false)

      expect do
        described_class.release_recovery(live_subscription, nil)
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid)
    end

    context "when the mandate has become active" do
      let(:mandate_status) { "active" }

      it "resumes renewals and queues the charge that came due while the mandate was pending" do
        expect(live_subscription).to be_overdue_for_charge

        expect do
          described_class.new.perform(live_subscription.id)
        end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid)
        expect(live_subscription.reload.credit_card).to eq(credit_card)

        expect(live_subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
        expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[live_subscription.id]])
      end

      context "when the renewal is not due yet" do
        let(:purchased_at) { 1.week.ago }

        it "resumes renewals without queuing a charge" do
          expect(live_subscription).not_to be_overdue_for_charge

          described_class.new.perform(live_subscription.id)

          expect(live_subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
          expect(RecurringChargeWorker.jobs).to be_empty
        end
      end

      it "does nothing a second time" do
        2.times { described_class.new.perform(live_subscription.id) }

        expect(RecurringChargeWorker.jobs.size).to eq(1)
      end
    end

    context "when queuing the overdue charge fails after the refresh committed" do
      let(:mandate_status) { "active" }

      def fail_enqueue_once
        calls = 0
        allow(RecurringChargeWorker).to receive(:perform_async).and_wrap_original do |original, *args|
          calls += 1
          raise Redis::CannotConnectError, "redis down" if calls == 1

          original.call(*args)
        end
      end

      it "keeps a durable marker and queues the charge exactly once on the retry" do
        fail_enqueue_once

        expect { described_class.new.perform(live_subscription.id) }.to raise_error(Redis::CannotConnectError)

        expect(live_subscription.reload).not_to be_renewal_disabled_due_to_indian_card_mandate
        expect(live_subscription).to be_indian_card_mandate_recovery_pending
        expect(RecurringChargeWorker.jobs).to be_empty

        described_class.new.perform(live_subscription.id)

        expect(RecurringChargeWorker.jobs.map { _1["args"] }).to eq([[live_subscription.id]])
        expect(live_subscription.reload).not_to be_indian_card_mandate_recovery_pending

        described_class.new.perform(live_subscription.id)

        expect(RecurringChargeWorker.jobs.size).to eq(1)
      end

      it "does not ask Stripe again on the retry" do
        fail_enqueue_once
        expect { described_class.new.perform(live_subscription.id) }.to raise_error(Redis::CannotConnectError)

        expect(ChargeProcessor).not_to receive(:get_mandate)
        described_class.new.perform(live_subscription.id)

        expect(RecurringChargeWorker.jobs.size).to eq(1)
      end

      it "queues nothing on the retry once the membership has been cancelled" do
        fail_enqueue_once
        expect { described_class.new.perform(live_subscription.id) }.to raise_error(Redis::CannotConnectError)
        live_subscription.update!(cancelled_at: 1.minute.ago, deactivated_at: 1.minute.ago)

        described_class.new.perform(live_subscription.id)

        expect(RecurringChargeWorker.jobs).to be_empty
        expect(live_subscription.reload).not_to be_indian_card_mandate_recovery_pending
      end

      context "when the renewal is not due yet" do
        let(:purchased_at) { 1.week.ago }

        it "leaves no marker behind" do
          described_class.new.perform(live_subscription.id)

          expect(live_subscription.reload).not_to be_indian_card_mandate_recovery_pending
          expect(RecurringChargeWorker.jobs).to be_empty
        end
      end
    end

    it "leaves no recovery marker while the mandate is inactive" do
      allow(ChargeProcessor).to receive(:get_mandate).and_return(
        Stripe::Mandate.construct_from(id: "mandate_pending", status: "inactive", payment_method: "pm_pending")
      )

      described_class.new.perform(live_subscription.id)

      expect(live_subscription.reload).not_to be_indian_card_mandate_recovery_pending
    end

    describe "when the chain cannot finish" do
      let(:generation) { described_class.next_generation(live_subscription.id) }
      let(:msg) { { "class" => described_class.name, "args" => [live_subscription.id, 0, generation] } }

      def exhaust_retries
        described_class.sidekiq_retries_exhausted_block.call(msg, ChargeProcessorError.new("stripe down"))
      end

      it "clears the recovery marker the failed refresh left behind, tells the buyer, and keeps renewals stopped and uncharged" do
        allow(ChargeProcessor).to receive(:get_mandate).and_raise(ChargeProcessorError, "stripe down")
        expect { described_class.new.perform(live_subscription.id, 0, generation) }.to raise_error(ChargeProcessorError)
        expect(live_subscription.reload).to be_indian_card_mandate_recovery_pending

        expect { exhaust_retries }.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid).with(live_subscription.id).once

        expect(live_subscription.reload).not_to be_indian_card_mandate_recovery_pending
        expect(live_subscription).to be_renewal_disabled_due_to_indian_card_mandate
        expect(live_subscription).to be_overdue_for_charge
        expect(RecurringChargeWorker.jobs).to be_empty
        expect(described_class.jobs).to be_empty
      end

      it "leaves a newer submission's recovery marker alone when an older chain's retries are exhausted" do
        live_subscription.update!(indian_card_mandate_recovery_pending: true)
        older = generation
        described_class.next_generation(live_subscription.id)
        msg["args"][2] = older

        expect { exhaust_retries }.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid)

        expect(live_subscription.reload).to be_indian_card_mandate_recovery_pending
      end

      it "keeps the marker once the renewal stop is cleared, because it is then the only record of an owed charge" do
        live_subscription.update!(indian_card_mandate_recovery_pending: true, renewal_disabled_due_to_indian_card_mandate: false)

        expect { exhaust_retries }.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_indian_card_mandate_invalid)

        expect(live_subscription.reload).to be_indian_card_mandate_recovery_pending
      end
    end

    it "ignores a live membership whose renewals were never stopped" do
      live_subscription.update!(renewal_disabled_due_to_indian_card_mandate: false)
      expect(ChargeProcessor).not_to receive(:get_mandate)

      described_class.new.perform(live_subscription.id)

      expect(RecurringChargeWorker.jobs).to be_empty
    end
  end
end
