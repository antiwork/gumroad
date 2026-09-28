# frozen_string_literal: true

describe "open 3DS authentication on a subscription charge" do
  def fingerprint_intent(last_payment_error: nil)
    StripeChargeIntent.new(
      payment_intent: Stripe::PaymentIntent.construct_from(
        id: "pi_fingerprint",
        status: "requires_action",
        client_secret: "pi_fingerprint_secret",
        next_action: {
          type: "use_stripe_sdk",
          use_stripe_sdk: { type: "stripe_3ds2_fingerprint" }
        },
        last_payment_error:
      )
    )
  end

  it "treats a fingerprint with no payment error as still open" do
    expect(fingerprint_intent.authentication_still_open?).to be true
  end

  it "does not treat a declined fingerprint as still open" do
    intent = fingerprint_intent(last_payment_error: { code: "card_declined", message: "Your card was declined." })
    type_only = fingerprint_intent(last_payment_error: { type: "card_error", decline_code: "generic_decline" })

    expect(intent.authentication_still_open?).to be false
    expect(type_only.authentication_still_open?).to be false
  end

  it "does not record charge_failed or cancel while the fingerprint is still open" do
    subscription = Subscription.new
    purchase = Purchase.new(purchase_state: "in_progress")
    intent = fingerprint_intent
    allow(purchase).to receive(:ensure_completion).and_yield
    allow(purchase).to receive(:process!) do
      purchase.errors.add(:base, "Sorry, something went wrong.")
      purchase.charge_intent = intent
    end
    allow(purchase).to receive(:in_progress?).and_return(true)
    allow(purchase).to receive(:save!)

    expect(CustomerLowPriorityMailer).not_to receive(:subscription_charge_failed)
    expect(UnsubscribeAndFailWorker).not_to receive(:perform_in)
    expect(FailAbandonedPurchaseWorker).to receive(:perform_in).with(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)

    subscription.process_purchase!(purchase, false, off_session: false)

    expect(purchase.purchase_state).to eq("in_progress")
  end

  it "records a decline when the fingerprint intent already has a payment error" do
    subscription = Subscription.new
    purchase = Purchase.new(purchase_state: "in_progress")
    intent = fingerprint_intent(last_payment_error: { code: "card_declined", decline_code: "insufficient_funds" })
    allow(purchase).to receive(:ensure_completion).and_yield
    allow(purchase).to receive(:process!) { purchase.charge_intent = intent }
    allow(purchase).to receive(:in_progress?).and_return(true)
    allow(purchase).to receive(:save!)
    allow(purchase).to receive(:mark_failed!)
    allow(subscription).to receive(:terminate_by).and_return(1.hour.from_now)
    allow(CustomerLowPriorityMailer).to receive_message_chain(:subscription_card_declined, :deliver_later)
    allow(ChargeDeclinedReminderWorker).to receive(:perform_in)
    expect(UnsubscribeAndFailWorker).to receive(:perform_in)
    expect(FailAbandonedPurchaseWorker).not_to receive(:perform_in)

    subscription.process_purchase!(purchase, false, off_session: false)

    expect(purchase).to have_received(:mark_failed!)
    expect(purchase.stripe_error_code).to eq("card_declined_insufficient_funds")
  end
end
