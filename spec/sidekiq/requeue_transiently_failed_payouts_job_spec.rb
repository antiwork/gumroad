# frozen_string_literal: true

describe RequeueTransientlyFailedPayoutsJob do
  let(:payout_period_end_date) { User::PayoutSchedule.manual_payout_end_date }

  def create_transient_failure(user:, failure_reason: Payment::FailureReason::PROCESSOR_RATE_LIMITED, **attrs)
    create(
      :payment_failed,
      user:,
      processor: PayoutProcessorType::STRIPE,
      failure_reason:,
      payout_period_end_date:,
      **attrs
    )
  end

  it "requeues the sellers whose payout failed on a rate limit, bypassing the payout-cycle gate" do
    seller = create(:user)
    create_transient_failure(user: seller)

    expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users) do |date, processor_type, users, options|
      expect(date).to eq(payout_period_end_date)
      expect(processor_type).to eq(PayoutProcessorType::STRIPE)
      expect(users.to_a).to eq([seller])
      expect(options).to eq(perform_async: true, retrying: true)
    end

    described_class.new.perform
  end

  it "requeues a payout that failed because the processor was unreachable" do
    seller = create(:user)
    create_transient_failure(user: seller, failure_reason: Payment::FailureReason::PROCESSOR_UNAVAILABLE)

    expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users) do |_date, _processor_type, users, _options|
      expect(users.to_a).to eq([seller])
    end

    described_class.new.perform
  end

  it "requeues each seller once no matter how many of their payouts failed" do
    seller = create(:user)
    2.times { create_transient_failure(user: seller) }

    expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users) do |_date, _processor_type, users, _options|
      expect(users.to_a).to eq([seller])
    end

    described_class.new.perform
  end

  it "does not requeue a failure the seller has to fix themselves" do
    create_transient_failure(user: create(:user), failure_reason: Payment::FailureReason::CANNOT_PAY)

    expect(Payouts).to_not receive(:create_payments_for_balances_up_to_date_for_users)

    described_class.new.perform
  end

  it "does not requeue a failure carrying no reason at all" do
    create_transient_failure(user: create(:user), failure_reason: nil)

    expect(Payouts).to_not receive(:create_payments_for_balances_up_to_date_for_users)

    described_class.new.perform
  end

  it "does not requeue a payout whose internal transfer could not be reversed, because the money is still on the seller's account" do
    seller = create(:user)
    create_transient_failure(
      user: seller,
      failure_reason: Payment::FailureReason::UNREVERSED_INTERNAL_TRANSFER,
      stripe_internal_transfer_id: "tr_stranded"
    )

    expect(Payouts).to_not receive(:create_payments_for_balances_up_to_date_for_users)

    described_class.new.perform
  end

  it "still requeues everyone else when one seller's transfer is stranded" do
    stranded_seller = create(:user)
    requeueable_seller = create(:user)
    create_transient_failure(
      user: stranded_seller,
      failure_reason: Payment::FailureReason::UNREVERSED_INTERNAL_TRANSFER,
      stripe_internal_transfer_id: "tr_stranded"
    )
    create_transient_failure(user: requeueable_seller)

    expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users) do |_date, _processor_type, users, _options|
      expect(users.to_a).to eq([requeueable_seller])
    end

    described_class.new.perform
  end

  it "does not requeue a payout whose bank-payout outcome is unknown, because Stripe may already have accepted it" do
    seller = create(:user)
    create_transient_failure(
      user: seller,
      failure_reason: Payment::FailureReason::PAYOUT_OUTCOME_UNKNOWN
    )

    expect(Payouts).to_not receive(:create_payments_for_balances_up_to_date_for_users)

    described_class.new.perform
  end

  it "does not requeue a failure from an earlier payout period" do
    create_transient_failure(user: create(:user), payout_period_end_date: payout_period_end_date - 7)

    expect(Payouts).to_not receive(:create_payments_for_balances_up_to_date_for_users)

    described_class.new.perform
  end

  it "does not requeue a PayPal failure, which RetryFailedPaypalPayoutsWorker owns" do
    create_transient_failure(user: create(:user), processor: PayoutProcessorType::PAYPAL, correlation_id: "12345")

    expect(Payouts).to_not receive(:create_payments_for_balances_up_to_date_for_users)

    described_class.new.perform
  end

  it "does nothing when no payout failed transiently" do
    expect(Payouts).to_not receive(:create_payments_for_balances_up_to_date_for_users)

    described_class.new.perform
  end

  it "does nothing when the kill switch is on" do
    create_transient_failure(user: create(:user))
    Feature.activate(:disable_transient_payout_failure_requeue)

    expect(Payouts).to_not receive(:create_payments_for_balances_up_to_date_for_users)

    described_class.new.perform
  ensure
    Feature.deactivate(:disable_transient_payout_failure_requeue)
  end

  # The examples above stub the payout path to assert routing. These drive the real one, because
  # what matters on a money path is what the requeue actually does to the seller's balance.
  describe "end to end" do
    let!(:merchant_account) { create(:merchant_account, user: seller, charge_processor_merchant_id: "acct_requeuetest") }

    let(:seller) do
      seller = create(:user_with_compliance_info)
      create(:ach_account, user: seller, stripe_bank_account_id: "ba_bankaccountid")
      seller.update!(user_risk_state: "compliant")
      seller
    end

    before do
      # Held by the seller's own connected account, so the payout is a single `Stripe::Payout.create`
      # with no internal transfer to stub.
      create(:balance, user: seller, merchant_account:, date: payout_period_end_date - 3, amount_cents: 500_00)
      # The two Stripe calls the payout leg makes: the drift guard's balance read, then the payout.
      allow(Stripe::Balance).to receive(:retrieve).and_return(
        Stripe::Balance.construct_from(
          object: "balance",
          available: [{ currency: "usd", amount: 500_00 }],
          pending: [{ currency: "usd", amount: 0 }]
        )
      )
      allow(Stripe::Payout).to receive(:create).and_return(
        Stripe::Payout.construct_from(id: "po_requeued", arrival_date: 2.days.from_now.to_i, application_fee_amount: nil)
      )
    end

    # The payout leg has to actually run: asserting only `payments.count` passes while the payment
    # is stuck in `creating` with a nil amount, which is what a broken Stripe boundary looks like.
    def expect_completed_payout(seller, amount_cents:)
      payment = seller.payments.last
      expect(payment.state).to eq("processing")
      expect(payment.amount_cents).to eq(amount_cents)
      expect(payment.stripe_transfer_id).to eq("po_requeued")
      expect(payment.failure_reason).to be_nil
    end

    it "creates a new payout for the failed seller and moves their balance out of unpaid" do
      create_transient_failure(user: seller, bank_account: seller.active_bank_account)

      expect do
        described_class.new.perform
        PayoutUsersWorker.drain
      end.to change { seller.payments.count }.by(1)

      expect_completed_payout(seller, amount_cents: 500_00)
      expect(seller.reload.unpaid_balance_cents).to eq(0)
    end

    context "when a monthly seller's next cycle is weeks away" do
      around do |example|
        # The parent setup creates the balance, so the time freeze must wrap the setup too.
        travel_to(Time.utc(2026, 8, 4, 14, 0, 0)) { example.run }
      end

      it "creates a new payout" do
        # The incident shape: a monthly seller's next cadence Friday is a month out, so the
        # payout-cycle gate would reject them and their balance would sit unpaid until then.
        period = User::PayoutSchedule.manual_payout_end_date
        seller.update!(payout_frequency: User::PayoutSchedule::MONTHLY)
        create_transient_failure(user: seller, bank_account: seller.active_bank_account, payout_period_end_date: period)
        expect(period + User::PayoutSchedule::PAYOUT_DELAY_DAYS).to be < seller.reload.next_payout_cycle_date

        expect do
          described_class.new.perform
          PayoutUsersWorker.drain
        end.to change { seller.payments.count }.by(1)

        expect_completed_payout(seller, amount_cents: 500_00)
        expect(seller.reload.unpaid_balance_cents).to eq(0)
      end
    end

    it "does not create a second payout while one is still processing" do
      create_transient_failure(user: seller, bank_account: seller.active_bank_account)
      create(:payment, user: seller, processor: PayoutProcessorType::STRIPE, state: "processing",
                       bank_account: seller.active_bank_account, payout_period_end_date:)

      expect do
        described_class.new.perform
        PayoutUsersWorker.drain
      end.to_not change { seller.payments.count }
    end

    it "does not pay a seller whose payouts have since been paused" do
      create_transient_failure(user: seller, bank_account: seller.active_bank_account)
      seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

      expect do
        described_class.new.perform
        PayoutUsersWorker.drain
      end.to_not change { seller.payments.count }
    end
  end

  context "when a seller is past the requeue cap" do
    it "reports them instead of requeueing, and still requeues everyone else" do
      exhausted = create(:user)
      (described_class::MAX_REQUEUE_ATTEMPTS + 1).times { create_transient_failure(user: exhausted) }
      requeueable = create(:user)
      create_transient_failure(user: requeueable)

      expect(ErrorNotifier).to receive(:notify).with(
        /1 seller\(s\) hit #{described_class::MAX_REQUEUE_ATTEMPTS} transient payout failures/o,
        hash_including(user_ids: [exhausted.id])
      )
      expect(Payouts).to receive(:create_payments_for_balances_up_to_date_for_users) do |_date, _processor_type, users, _options|
        expect(users.to_a).to eq([requeueable])
      end

      described_class.new.perform
    end

    it "does not call the payout path when every seller is past the cap" do
      exhausted = create(:user)
      (described_class::MAX_REQUEUE_ATTEMPTS + 1).times { create_transient_failure(user: exhausted) }

      expect(ErrorNotifier).to receive(:notify)
      expect(Payouts).to_not receive(:create_payments_for_balances_up_to_date_for_users)

      described_class.new.perform
    end

    it "reports a seller once per period, staying quiet on the next day's run" do
      # The job runs daily against a week-long period. Counting cannot dedupe this: requeueing has
      # stopped for this seller, so their failure count no longer moves and any count-based
      # condition would hold on every later run.
      exhausted = create(:user)
      (described_class::MAX_REQUEUE_ATTEMPTS + 1).times { create_transient_failure(user: exhausted) }

      expect(ErrorNotifier).to receive(:notify).once
      described_class.new.perform

      expect(ErrorNotifier).to_not receive(:notify)
      expect(Payouts).to_not receive(:create_payments_for_balances_up_to_date_for_users)
      described_class.new.perform
    end

    it "reports a seller who crosses the cap by more than one failure" do
      # Nothing guarantees the count lands exactly one past the cap: several payouts can fail in the
      # same batch, so the seller's first appearance here can already be well over it.
      exhausted = create(:user)
      (described_class::MAX_REQUEUE_ATTEMPTS + 3).times { create_transient_failure(user: exhausted) }

      expect(ErrorNotifier).to receive(:notify).with(
        /1 seller\(s\) hit #{described_class::MAX_REQUEUE_ATTEMPTS} transient payout failures/o,
        hash_including(user_ids: [exhausted.id])
      )

      described_class.new.perform
    end

    it "reports the same seller again for a new payout period" do
      # The dedupe is per period, not forever — a fresh period is a fresh problem worth an alert.
      exhausted = create(:user)
      (described_class::MAX_REQUEUE_ATTEMPTS + 1).times { create_transient_failure(user: exhausted) }

      expect(ErrorNotifier).to receive(:notify).once
      described_class.new.perform

      next_period = payout_period_end_date + 7
      (described_class::MAX_REQUEUE_ATTEMPTS + 1).times do
        create_transient_failure(user: exhausted, payout_period_end_date: next_period)
      end
      allow(User::PayoutSchedule).to receive(:manual_payout_end_date).and_return(next_period)

      expect(ErrorNotifier).to receive(:notify).once
      described_class.new.perform
    end
  end
end
