# frozen_string_literal: true

require "spec_helper"

describe CheckIndianCardMandateRegistrationJob do
  def applicable_subscription(overdue: false, renewal_disabled: true)
    instance_double(
      Subscription,
      id: 789,
      india_card_mandate_reliability_enabled?: true,
      alive?: true,
      credit_card_to_charge: instance_double(CreditCard, id: 456),
      renewal_disabled_due_to_indian_card_mandate?: renewal_disabled,
      overdue_for_charge?: overdue,
      charges_completed?: false
    )
  end

  it "runs the setup-intent e-mandate check for the given purchase" do
    purchase = create(:purchase_in_progress)
    other_purchase = create(:purchase_in_progress)

    expect(Purchase).to receive(:find).with(purchase.id).and_return(purchase)
    expect(purchase).to receive(:check_indian_card_setup_intent_mandate_was_registered)
    expect(other_purchase).not_to receive(:check_indian_card_setup_intent_mandate_was_registered)

    described_class.new.perform(purchase.id)
  end

  it "is configured for the low queue with a unique lock" do
    expect(described_class.sidekiq_options["queue"]).to eq(:low)
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
  end

  it "rechecks a pending mandate when reliability enforcement is active" do
    subscription = applicable_subscription
    purchase = instance_double(
      Purchase,
      id: 123,
      credit_card_id: 456,
      subscription:,
      india_card_mandate_reliability_enabled?: true,
      indian_card_mandate_status: "pending",
      verify_indian_card_mandate_registration!: nil
    )
    allow(Purchase).to receive(:find).with(123).and_return(purchase)

    expect(described_class).to receive(:perform_in).with(1.minute, 123, 1)

    described_class.new.perform(123)
  end

  it "notifies the buyer when a mandate remains pending after the final check" do
    subscription = applicable_subscription
    purchase = instance_double(
      Purchase,
      id: 123,
      credit_card_id: 456,
      subscription:,
      india_card_mandate_reliability_enabled?: true,
      indian_card_mandate_status: "pending",
      verify_indian_card_mandate_registration!: nil
    )
    allow(Purchase).to receive(:find).with(123).and_return(purchase)

    expect(subscription).to receive(:update_renewal_for_indian_card_mandate!).with(
      "pending",
      expected_credit_card_id: 456,
      notify_buyer: true,
      notify_buyer_if_already_disabled: true
    )
    expect(described_class).to receive(:perform_in).with(
      1.day,
      123,
      described_class::PENDING_RECHECK_DELAYS.length + 1
    )

    described_class.new.perform(123, described_class::PENDING_RECHECK_DELAYS.length)
  end

  it "keeps checking after the buyer receives the pending notice" do
    subscription = applicable_subscription
    purchase = instance_double(
      Purchase,
      id: 123,
      credit_card_id: 456,
      subscription:,
      india_card_mandate_reliability_enabled?: true,
      indian_card_mandate_status: "pending",
      verify_indian_card_mandate_registration!: nil
    )
    allow(Purchase).to receive(:find).with(123).and_return(purchase)
    next_count = described_class::PENDING_RECHECK_DELAYS.length + 2

    expect(described_class).to receive(:perform_in).with(1.day, 123, next_count)

    described_class.new.perform(123, next_count - 1)
  end

  it "restarts an overdue renewal after the mandate becomes active" do
    subscription = applicable_subscription(overdue: true, renewal_disabled: false)
    purchase = instance_double(
      Purchase,
      id: 123,
      credit_card_id: 456,
      subscription:,
      india_card_mandate_reliability_enabled?: true,
      indian_card_mandate_status: "active",
      verify_indian_card_mandate_registration!: nil
    )
    allow(Purchase).to receive(:find).with(123).and_return(purchase)

    expect(RecurringChargeWorker).to receive(:perform_async).with(789)

    described_class.new.perform(123)
  end

  it "stops checks after all subscription charges are complete" do
    subscription = applicable_subscription
    allow(subscription).to receive(:charges_completed?).and_return(true)
    purchase = instance_double(
      Purchase,
      id: 123,
      credit_card_id: 456,
      subscription:,
      india_card_mandate_reliability_enabled?: true
    )
    allow(Purchase).to receive(:find).with(123).and_return(purchase)

    expect(purchase).not_to receive(:verify_indian_card_mandate_registration!)
    expect(described_class).not_to receive(:perform_in)

    described_class.new.perform(123)
  end


  it "stops checks after the subscription changes cards" do
    subscription = applicable_subscription
    allow(subscription.credit_card_to_charge).to receive(:id).and_return(999)
    purchase = instance_double(
      Purchase,
      id: 123,
      credit_card_id: 456,
      subscription:,
      india_card_mandate_reliability_enabled?: true
    )
    allow(Purchase).to receive(:find).with(123).and_return(purchase)

    expect(purchase).not_to receive(:verify_indian_card_mandate_registration!)

    described_class.new.perform(123, 1)
  end
end
