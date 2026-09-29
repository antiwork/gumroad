# frozen_string_literal: true

require "spec_helper"

# A client-confirmed purchase failed before its PaymentIntent settled, and the intent then succeeds.
# These run the real webhook worker, order finalizer, ledger and access creation; only Stripe SDK
# class methods are stubbed, and any provider write raises.
describe Purchase::FinalizeConfirmedChargeService, "late success after an earlier failure" do
  include ClientConfirmedLateSuccessHelpers

  { platform_held: 1, destination_charge: 1, connect_direct: 0 }.each do |mode, ledger_rows|
    context "with #{mode} funds" do
      it "completes a cleanly captured purchase once, with ledger, access and receipt" do
        _order, charge, (purchase, *) = build_cart(mode:)
        fail_via_webhook(charge)
        expect(purchase.reload).to be_failed
        Sidekiq::Worker.clear_all

        deliver(charge, "payment_intent.succeeded")

        expect(purchase.reload).to be_successful
        expect(purchase.stripe_transaction_id).to eq("ch_late_#{charge.id}")
        expect(purchase.stripe_error_code).to be_nil
        expect(purchase.balance_transactions.count).to eq(ledger_rows)
        expect(ledger_cents([purchase])).to eq(charge.amount_cents) if ledger_rows == 1
        expect(access_count([purchase])).to eq(1)
        expect(SendChargeReceiptJob.jobs.size).to eq(1)
        expect(ActivateIntegrationsWorker.jobs.size).to eq(1)
      end

      {
        "fully refunded" => ->(charge) { { refunded: true, amount_refunded: charge.amount_cents } },
        "partially refunded" => ->(_charge) { { amount_refunded: 3_00 } },
        "disputed" => ->(_charge) { { dispute: "dp_late" } },
        "captured for a different amount" => ->(charge) { { amount: charge.amount_cents - 1 } },
        "captured in a different currency" => ->(_charge) { { currency: "eur" } },
      }.each do |label, charge_override|
        it "leaves the purchase failed when Stripe reports the charge #{label}, with no local refund" do
          order, charge, (purchase, *) = build_cart(mode:)
          fail_via_webhook(charge)
          provider[:charge] = charge_override.call(charge)
          Sidekiq::Worker.clear_all

          deliver(charge, "payment_intent.succeeded")
          Order::FinalizeConfirmedChargeService.new(order: Order.find(order.id)).perform

          expect(purchase.reload).to be_failed
          expect(purchase.stripe_transaction_id).to be_nil
          expect(purchase.refunds).to be_empty
          expect(purchase.balance_transactions).to be_empty
          expect(access_count([purchase])).to eq(0)
          expect(SendChargeReceiptJob.jobs.size).to eq(0)
          expect(ActivateIntegrationsWorker.jobs.size).to eq(0)
        end
      end

      # handle_event_failed! writes mark_failed! on purchases it loaded before a concurrent
      # finalize booked them. Replays after that must not fulfill a second time.
      it "does not re-fulfill a booked purchase that a stale failure overwrote" do
        order, charge, (purchase, *) = build_cart(mode:)
        stale_purchase = Purchase.find(purchase.id)
        deliver(charge, "payment_intent.succeeded")
        expect(purchase.reload).to be_successful
        stale_purchase.mark_failed!
        expect(purchase.reload).to be_failed
        Sidekiq::Worker.clear_all

        expect do
          deliver(charge, "payment_intent.succeeded")
          Order::FinalizeConfirmedChargeService.new(order: Order.find(order.id)).perform
        end.not_to change { [purchase.reload.purchase_state, purchase.balance_transactions.count, access_count([purchase])] }

        expect(purchase.balance_transactions.count).to eq(ledger_rows)
        expect(SendChargeReceiptJob.jobs.size).to eq(0)
        expect(ActivateIntegrationsWorker.jobs.size).to eq(0)
      end
    end
  end

  context "when settlement data arrives after a stale failure event" do
    { destination_charge: 1, connect_direct: 0 }.each do |mode, ledger_rows|
      %i[webhook manual_sync strict_sync].each do |entry_point|
        it "recovers #{mode} through #{entry_point} without repeating fulfillment" do
          _order, charge, (purchase, *) = build_cart(mode:)
          provider[:charge] = { balance_transaction: nil }
          deliver(charge, "payment_intent.succeeded")

          expect(purchase.reload).to be_in_progress
          expect(purchase.stripe_transaction_id).to eq("ch_late_#{charge.id}")
          expect(purchase.succeeded_at).to be_nil
          expect(purchase.balance_transactions).to be_empty
          expect(access_count([purchase])).to eq(0)

          HandleStripeEventWorker.new.perform(failed_event(charge))
          expect(purchase.reload).to be_failed
          provider[:charge] = {}
          Sidekiq::Worker.clear_all

          if entry_point == :webhook
            deliver(charge, "payment_intent.succeeded")
          else
            sync = Purchase::SyncStatusWithChargeProcessorService.new(purchase, require_final_charge_status: entry_point == :strict_sync)
            expect(sync.perform).to be(true)
          end
          deliver(charge, "payment_intent.succeeded")

          expect(purchase.reload).to be_successful
          expect(purchase.succeeded_at).to be_present
          expect(purchase.stripe_error_code).to be_nil
          expect(purchase.balance_transactions.count).to eq(ledger_rows)
          expect(ledger_cents([purchase])).to eq(charge.amount_cents) if ledger_rows == 1
          expect(access_count([purchase])).to eq(1)
          expect(ActivateIntegrationsWorker.jobs.size).to eq(1)
        end
      end
    end

    it "rejects a saved charge ID that differs from the captured charge" do
      _order, charge, (purchase, *) = build_cart(mode: :destination_charge)
      fail_via_webhook(charge)
      purchase.reload.update!(stripe_transaction_id: "ch_other_capture")

      deliver(charge, "payment_intent.succeeded")

      expect(purchase.reload).to be_failed
      expect(purchase.stripe_transaction_id).to eq("ch_other_capture")
      expect(purchase.balance_transactions).to be_empty
      expect(access_count([purchase])).to eq(0)
    end
  end

  context "with several purchases on one captured charge" do
    it "completes every failed purchase of a normal cart, booking exactly the captured amount" do
      _order, charge, purchases = build_cart(items: 3)
      fail_via_webhook(charge)
      expect(purchases.map { _1.reload.purchase_state }).to eq(%w[failed failed failed])

      deliver(charge, "payment_intent.succeeded")

      expect(purchases.map { _1.reload.purchase_state }).to eq(%w[successful successful successful])
      expect(ledger_cents(purchases)).to eq(charge.amount_cents)
      expect(access_count(purchases)).to eq(3)
    end

    it "completes failed purchases next to an in-progress sibling of the same capture" do
      _order, charge, purchases = build_cart(items: 3)
      purchases.drop(1).each { _1.update_columns(purchase_state: "failed") }

      deliver(charge, "payment_intent.succeeded")

      expect(purchases.map { _1.reload.purchase_state }).to eq(%w[successful successful successful])
      expect(ledger_cents(purchases)).to eq(charge.amount_cents)
    end

    # A charge whose capture excludes a failed purchase: booking it would split more than Stripe took.
    [[:first, "a sibling not finalized yet"], [:last, "an already booked sibling"]].each do |failed_position, sibling|
      it "leaves a failed purchase the capture does not cover failed, next to #{sibling}" do
        order, charge, purchases = build_cart(items: 2)
        failed, covered = failed_position == :first ? purchases : purchases.reverse
        charge.update!(amount_cents: covered.total_transaction_cents,
                       gumroad_amount_cents: covered.total_transaction_amount_for_gumroad_cents)
        failed.update_columns(purchase_state: "failed")

        deliver(charge, "payment_intent.succeeded")
        Order::FinalizeConfirmedChargeService.new(order: Order.find(order.id)).perform

        expect(covered.reload).to be_successful
        expect(failed.reload).to be_failed
        expect(failed.balance_transactions).to be_empty
        # The existing split still weights the uncovered purchase, so the sibling books exactly
        # its largest-remainder share of the capture, which here is a cent under it.
        weights = purchases.map(&:total_transaction_cents)
        covered_share = Charge.allocate_by_largest_remainder(charge.amount_cents, weights, charge.amount_cents)[purchases.index(covered)]
        expect(ledger_cents([covered])).to eq(covered_share)
        expect(covered_share).to be <= charge.amount_cents
        expect(access_count(purchases)).to eq(1)
      end
    end

    it "revives a failed peer next to a booked peer that a stale failure overwrote, booking only its own share" do
      _order, charge, (booked, failed) = build_cart(items: 2)
      charge_intent = ChargeProcessor.get_charge_intent(charge.merchant_account, charge.stripe_payment_intent_id)
      described_class.new(purchase: booked, charge_intent:).perform
      fail_via_webhook(charge)
      booked.reload.update_columns(purchase_state: "failed")

      deliver(charge, "payment_intent.succeeded")

      expect(booked.reload).to be_failed
      expect(booked.balance_transactions.count).to eq(1)
      expect(failed.reload).to be_successful
      expect(ledger_cents([booked, failed])).to eq(charge.amount_cents)
    end

    it "leaves every failed purchase failed when their totals exceed what the charge captured" do
      _order, charge, (first, second) = build_cart(items: 2)
      charge.update!(amount_cents: second.total_transaction_cents, gumroad_amount_cents: second.total_transaction_amount_for_gumroad_cents)
      fail_via_webhook(charge)

      deliver(charge, "payment_intent.succeeded")

      expect([first.reload, second.reload].map(&:purchase_state)).to eq(%w[failed failed])
      expect(ledger_cents([first, second])).to eq(0)
      expect(access_count([first, second])).to eq(0)
    end

    it "leaves a failed purchase the capture only partly covers failed" do
      _order, charge, (sibling, failed) = build_cart(items: 2)
      charge.update!(amount_cents: sibling.total_transaction_cents + 5_00)
      failed.update_columns(purchase_state: "failed")

      deliver(charge, "payment_intent.succeeded")

      expect(sibling.reload).to be_successful
      expect(failed.reload).to be_failed
      expect(failed.balance_transactions).to be_empty
    end
  end

  context "with a gift" do
    it "completes the gift and grants the giftee access after the gifter purchase failed" do
      _order, charge, (gifter_purchase, *) = build_cart(gift: true)
      fail_via_webhook(charge)
      gift = gifter_purchase.reload.gift_given
      expect(gift.reload).to be_failed
      expect(gift.giftee_purchase).to be_gift_receiver_purchase_failed

      deliver(charge, "payment_intent.succeeded")

      expect(gifter_purchase.reload).to be_successful
      expect(gift.reload).to be_successful
      expect(gift.giftee_purchase).to be_gift_receiver_purchase_successful
      expect(gift.giftee_purchase.url_redirect).to be_present
      expect(ledger_cents([gifter_purchase])).to eq(charge.amount_cents)
    end
  end

  context "with a buyer-currency presentment" do
    it "keeps the snapshot through the failure webhook and books the late success in the buyer's currency" do
      _order, charge, (purchase, *) = build_cart
      charge_presentment = create(:charge_presentment, charge:, presentment_currency: Currency::EUR, presentment_total_cents: 9_00,
                                                       presentment_gumroad_amount_cents: 90, stripe_fx_quote_id: nil,
                                                       stripe_fx_quote_expires_at: nil, fx_rate: nil)
      create(:purchase_presentment, purchase:, charge_presentment:, presentment_currency: Currency::EUR, presentment_price_cents: 9_00,
                                    presentment_gumroad_tax_cents: 0, presentment_total_cents: 9_00, presentment_gumroad_amount_cents: 90)
      provider[:charge] = { amount: 9_00, currency: "eur" }
      fail_via_webhook(charge)
      expect(purchase.reload).to be_failed
      expect(charge.reload.charge_presentment).to eq(charge_presentment)

      deliver(charge, "payment_intent.succeeded")

      expect(purchase.reload).to be_successful
      expect(purchase.buyer_presentment_currency).to eq(Currency::EUR)
      expect(purchase.buyer_presentment_total_cents).to eq(9_00)
      # The ledger stays in canonical dollars; refunds read the buyer-currency leg from the snapshot.
      expect(purchase.balance_transactions.sole).to have_attributes(issued_amount_currency: Currency::USD, issued_amount_gross_cents: charge.amount_cents)
    end

    it "leaves the purchase failed when Stripe captured a different buyer-currency amount" do
      _order, charge, (purchase, *) = build_cart
      charge_presentment = create(:charge_presentment, charge:, presentment_currency: Currency::EUR, presentment_total_cents: 9_00)
      create(:purchase_presentment, purchase:, charge_presentment:, presentment_currency: Currency::EUR)
      provider[:charge] = { amount: 8_99, currency: "eur" }
      fail_via_webhook(charge)

      deliver(charge, "payment_intent.succeeded")

      expect(purchase.reload).to be_failed
      expect(purchase.balance_transactions).to be_empty
    end
  end

  context "with a new membership" do
    it "completes the purchase with a subscription on the card saved from the intent" do
      # Tiered membership prices live on the default tier, not the product's price row.
      product = create(:membership_product, user: seller, price_cents: 5_00)
      _order, charge, (purchase, *) = build_cart(product:, line_item: { price_id: product.prices.alive.first.external_id, perceived_price_cents: 5_00 })
      expect(purchase).to be_in_progress
      provider[:intent] = { setup_future_usage: "off_session", customer: "cus_late" }
      provider[:charge] = {
        payment_method_details: { type: "card", card: { brand: "visa", last4: "4242", exp_month: 12, exp_year: 2040, fingerprint: "fp_late",
                                                        country: "US", checks: { address_postal_code_check: "pass" } } }
      }
      fail_via_webhook(charge)
      expect(purchase.reload).to be_failed

      deliver(charge, "payment_intent.succeeded")

      expect(purchase.reload).to be_successful
      expect(purchase.credit_card).to have_attributes(stripe_customer_id: "cus_late", processor_payment_method_id: "pm_late")
      expect(purchase.subscription).to be_present
      expect(purchase.subscription.credit_card).to eq(purchase.credit_card)
      expect(purchase.subscription).to be_alive
      expect(ledger_cents([purchase])).to eq(charge.amount_cents)
    end
  end

  it "leaves a failed installment purchase failed, since client-confirm saves no card for later installments" do
    product = create(:product, :with_installment_plan, user: seller)
    first_installment_cents = product.installment_plan.calculate_installment_payment_price_cents(product.price_cents)
    _order, charge, (purchase, *) = build_cart(product:, line_item: { pay_in_installments: true, perceived_price_cents: first_installment_cents })
    expect(purchase).to be_is_installment_payment
    expect(purchase).to be_in_progress
    fail_via_webhook(charge)

    deliver(charge, "payment_intent.succeeded")

    expect(purchase.reload).to be_failed
    expect(purchase.subscription).to be_nil
    expect(purchase.balance_transactions).to be_empty
  end

  context "with a subscription change whose failure already reverted the subscription" do
    it "leaves a failed upgrade purchase failed" do
      _order, charge, (purchase, *) = build_cart
      fail_via_webhook(charge)
      purchase.reload.update_flag!(:is_upgrade_purchase, true, true)

      deliver(charge, "payment_intent.succeeded")

      expect(purchase.reload).to be_failed
      expect(purchase.balance_transactions).to be_empty
    end

    it "leaves a failed purchase on an existing subscription failed" do
      _order, charge, (purchase, *) = build_cart
      fail_via_webhook(charge)
      subscription = create(:subscription, link: purchase.link, deactivated_at: 1.day.ago)
      purchase.reload.update_columns(subscription_id: subscription.id)

      deliver(charge, "payment_intent.succeeded")

      expect(purchase.reload).to be_failed
      expect(subscription.reload.deactivated_at).to be_present
      expect(purchase.balance_transactions).to be_empty
    end
  end

  it "leaves a failed purchase with a local refund failed" do
    _order, charge, (purchase, *) = build_cart
    fail_via_webhook(charge)
    create(:refund, purchase:)

    deliver(charge, "payment_intent.succeeded")

    expect(purchase.reload).to be_failed
    expect(purchase.balance_transactions).to be_empty
  end

  it "leaves a purchase that failed for its own reason (error_code) failed" do
    _order, charge, (purchase, *) = build_cart
    fail_via_webhook(charge)
    purchase.reload.update_columns(error_code: PurchaseErrorCode::PPP_CARD_COUNTRY_NOT_MATCHING)

    deliver(charge, "payment_intent.succeeded")

    expect(purchase.reload).to be_failed
  end

  it "leaves a failed purchase failed while the intent is still processing" do
    order, charge, (purchase, *) = build_cart
    fail_via_webhook(charge)
    provider[:pi_status] = "processing"

    responses = Order::FinalizeConfirmedChargeService.new(order: Order.find(order.id)).perform

    expect(purchase.reload).to be_failed
    expect(responses.values.sole[:success]).to be(false)
  end
end
