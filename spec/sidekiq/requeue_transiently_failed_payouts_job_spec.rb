# frozen_string_literal: true

describe RequeueTransientlyFailedPayoutsJob do
  let(:payout_period_end_date) { User::PayoutSchedule.next_scheduled_payout_end_date }

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
  end
end
