# frozen_string_literal: true

require "spec_helper"

describe SendStripeBalanceCheckNotificationJob do
  describe "#perform" do
    let(:balance_check) do
      instance_double(
        StripeBalanceCheckService,
        balance_read_at: Time.utc(2026, 9, 15, 14, 2, 30),
        upcoming_payouts_cents: 300_000_00,
        available_cents: 150_000_00,
        pending_cents: 50_000_00,
        current_balance_cents: 200_000_00,
        topup_amount_cents: 100_000_00,
        topup_needed?: true,
        day_before_first_run?: false,
        per_run_estimate_cents: { tuesday: 120_000_00, wednesday: 90_000_00, thursday: 90_000_00 },
        payout_end_date: Date.new(2026, 9, 11),
        next_payout_run_at: Time.utc(2026, 9, 16, 10, 0),
        cycle_last_run_at: Time.utc(2026, 9, 18, 10, 0),
        swept_to_bank_last_day_cents: 301_513_34,
        sweeps_in_flight_last_day_cents: 12_000_00
      )
    end

    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(StripeBalanceCheckService).to receive(:new).and_return(balance_check)
    end

    context "when the balance is insufficient" do
      it "sends a notification leading with the conservative verdict, naming the read time, both gaps and the action, and sets the redis key to true" do
        described_class.new.perform

        expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Stripe Balance Check", kind_of(String), "red")
        message = InternalNotificationWorker.jobs.last["args"][2]
        expect(message).to start_with("Action needed, conservatively before the next run: Wednesday, September 16 at 10:00 UTC (6:00 AM ET).\n")
        expect(message).to include("Stripe balance as of 14:02 UTC: $200,000 ($150,000 available + $50,000 pending, which normally settles")
        expect(message).to include("Seller payouts for balances up to September 11 need $300,000")
        expect(message).to include("the next run is Wednesday, September 16 at 10:00 UTC (6:00 AM ET) and the last run of the cycle is Friday, September 18 at 10:00 UTC (6:00 AM ET).")
        expect(message).to include("Gap counting pending (available + pending against the whole cycle, assuming the $50,000 pending settles before it is drawn): $100,000. " \
                                   "Gap if none of the pending settles in time (available alone against the whole cycle): $150,000.")
        expect(message).to include("Of Stripe's USD bank payouts created in the last 24 hours, $301,513.34 has reached the bank and $12,000 is still in flight.")
        expect(message).to include("Top up $100,000, the gap counting pending. The check compares the whole cycle with available + pending and does not " \
                                   "measure what the next run alone draws, so treat the next run as the deadline to be safe. Nothing tops up automatically")
        expect(message).not_to include("no later than")
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("true")
      end

      it "labels a cohort whose run already passed this cycle as still unpaid rather than as an upcoming run, and keeps it in the total" do
        described_class.new.perform

        message = InternalNotificationWorker.jobs.last["args"][2]
        expect(message).to include("By weekday cohort (estimates, which err high): runs still ahead: Wednesday $90,000, Thursday $90,000; " \
                                   "already run this cycle and still unpaid (in the total above; re-issued or manual payouts can still draw it): Tuesday $120,000.")
        expect(message).to include("need $300,000 from Gumroad's Stripe balance in total, counting any sellers an earlier run this cycle left unpaid.")
      end

      it "still sends the red verdict when the optional cohort lookup fails, and reports the failure" do
        error = ActiveRecord::StatementTimeout.new("Query execution was interrupted")
        allow(balance_check).to receive(:per_run_estimate_cents).and_raise(error)
        expect(ErrorNotifier).to receive(:notify).with(error)

        described_class.new.perform

        expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Stripe Balance Check", kind_of(String), "red")
        message = InternalNotificationWorker.jobs.last["args"][2]
        expect(message).to include("By weekday cohort: unavailable this time (the lookup failed and was reported). The total above is unaffected.")
        expect(message).to include("Top up $100,000")
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("true")
      end

      it "sends nothing and keeps the previous state when the core estimate fails" do
        $redis.set(RedisKey.stripe_balance_topup_needed, true)
        allow(StripeBalanceCheckService).to receive(:new).and_call_original
        allow(PayoutEstimates).to receive(:estimate_gumroad_held_stripe_cents_per_user).and_raise(ActiveRecord::StatementTimeout)

        expect { described_class.new.perform }.to raise_error(ActiveRecord::StatementTimeout)
        expect(InternalNotificationWorker.jobs.size).to eq(0)
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("true")
      end

      it "leads with no action when available + pending covers the cycle, without claiming the next run is covered by settled funds" do
        allow(balance_check).to receive_messages(topup_needed?: false, topup_amount_cents: -100_000_00, pending_cents: 250_000_00, current_balance_cents: 400_000_00)
        $redis.set(RedisKey.stripe_balance_topup_needed, true)

        described_class.new.perform

        message = InternalNotificationWorker.jobs.last["args"][2]
        expect(message).to start_with("No action needed yet.\n")
        expect(message).to include("Gap counting pending (available + pending against the whole cycle, assuming the $250,000 pending settles before it is drawn): $0. " \
                                   "Gap if none of the pending settles in time (available alone against the whole cycle): $150,000.")
        expect(message).to include("Nothing to do yet: available + pending covers the whole cycle, assuming the pending settles before it is drawn. " \
                                   "This does not check that settled funds alone cover the next run. A re-check goes out on the Monday before the cycle's first run.")
        expect(message).not_to include("covers the next run")
      end
    end

    context "when the balance is sufficient" do
      before do
        allow(balance_check).to receive_messages(topup_needed?: false, topup_amount_cents: -100_000_00, pending_cents: 250_000_00, current_balance_cents: 400_000_00)
      end

      it "does not notify and sets the redis key to false" do
        $redis.set(RedisKey.stripe_balance_topup_needed, false)

        described_class.new.perform

        expect(InternalNotificationWorker.jobs.size).to eq(0)
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("false")
      end

      it "sends a green all-clear when the previous check needed a top-up" do
        $redis.set(RedisKey.stripe_balance_topup_needed, true)

        described_class.new.perform

        expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Stripe Balance Check", kind_of(String), "green")
        expect(InternalNotificationWorker.jobs.last["args"][2]).to include("Nothing to do yet: available + pending covers the whole cycle, assuming the pending settles before it is drawn.")
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("false")
      end

      it "preserves the all-clear until enqueueing succeeds" do
        $redis.set(RedisKey.stripe_balance_topup_needed, true)
        allow(InternalNotificationWorker).to receive(:perform_async).and_raise(Redis::CannotConnectError)

        expect { described_class.new.perform }.to raise_error(Redis::CannotConnectError)
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("true")
        expect(InternalNotificationWorker.jobs.size).to eq(0)

        allow(InternalNotificationWorker).to receive(:perform_async).and_call_original
        described_class.new.perform

        expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Stripe Balance Check", kind_of(String), "green")
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("false")
      end

      it "leaves the previous state in place when building the message fails, so the retry still sends the all-clear" do
        $redis.set(RedisKey.stripe_balance_topup_needed, true)
        attempts = 0
        allow(balance_check).to receive(:swept_to_bank_last_day_cents) do
          attempts += 1
          raise Stripe::APIConnectionError, "connection refused" if attempts == 1
          0
        end

        expect { described_class.new.perform }.to raise_error(Stripe::APIConnectionError)
        expect(InternalNotificationWorker.jobs.size).to eq(0)
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("true")

        described_class.new.perform

        expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Stripe Balance Check", kind_of(String), "green")
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("false")
      end

      it "re-sends the verdict on the Monday before the cycle's first run, with no transition to report and every cohort ahead" do
        allow(balance_check).to receive_messages(day_before_first_run?: true, next_payout_run_at: Time.utc(2026, 9, 15, 10, 0))
        $redis.set(RedisKey.stripe_balance_topup_needed, false)

        described_class.new.perform

        expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Stripe Balance Check", kind_of(String), "green")
        message = InternalNotificationWorker.jobs.last["args"][2]
        expect(message).to start_with("No action needed yet.\n")
        expect(message).to include("runs still ahead: Tuesday $120,000, Wednesday $90,000, Thursday $90,000.")
        expect(message).not_to include("already run this cycle")
        expect(message).to include("This is the Monday re-check before the cycle's first run.")
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("false")
      end

      it "still sends the all-clear transition when the optional cohort lookup fails" do
        $redis.set(RedisKey.stripe_balance_topup_needed, true)
        allow(balance_check).to receive(:per_run_estimate_cents).and_raise(ActiveRecord::StatementTimeout)
        allow(ErrorNotifier).to receive(:notify)

        described_class.new.perform

        expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Stripe Balance Check", kind_of(String), "green")
        expect(InternalNotificationWorker.jobs.last["args"][2]).to include("By weekday cohort: unavailable this time")
        expect(ErrorNotifier).to have_received(:notify).with(kind_of(ActiveRecord::StatementTimeout))
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to eq("false")
      end

      it "does not re-send the verdict on the other days of the week" do
        $redis.set(RedisKey.stripe_balance_topup_needed, false)

        described_class.new.perform

        expect(InternalNotificationWorker.jobs.size).to eq(0)
      end
    end

    it "does nothing outside production" do
      allow(Rails.env).to receive(:production?).and_return(false)

      described_class.new.perform

      expect(InternalNotificationWorker.jobs.size).to eq(0)
    end

    context "when the disable_stripe_balance_check_notification flag is active" do
      before { Feature.activate(:disable_stripe_balance_check_notification) }

      it "does not check the balance, notify, or set the redis key" do
        expect(StripeBalanceCheckService).not_to receive(:new)

        described_class.new.perform

        expect(InternalNotificationWorker.jobs.size).to eq(0)
        expect($redis.get(RedisKey.stripe_balance_topup_needed)).to be_nil
      end
    end
  end
end
