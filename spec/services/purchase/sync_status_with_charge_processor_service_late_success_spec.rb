# frozen_string_literal: true

require "spec_helper"

# Manual status sync of a client-confirmed purchase that failed before its PaymentIntent settled.
# The sync must hand the still-failed row to the finalizer, whose late-success guards decide.
describe Purchase::SyncStatusWithChargeProcessorService, "for a failed client-confirmed purchase" do
  include ClientConfirmedLateSuccessHelpers

  def ledger_snapshot(purchases)
    ids = purchases.map(&:id)
    {
      states: Purchase.where(id: ids).order(:id).pluck(:purchase_state),
      stripe_transaction_ids: Purchase.where(id: ids).order(:id).pluck(:stripe_transaction_id),
      ledger_rows: BalanceTransaction.where(purchase_id: ids).count,
      ledger_cents: ledger_cents(purchases),
      access: access_count(purchases),
      subscriptions: Subscription.joins(:purchases).where(purchases: { id: ids }).count,
    }
  end

  def expect_refused(purchases, service)
    before = ledger_snapshot(purchases)
    Sidekiq::Worker.clear_all

    expect(service.perform).to be(false)

    expect(ledger_snapshot(purchases)).to eq(before)
    expect(before[:states]).to all(eq("failed"))
    expect(SendChargeReceiptJob.jobs.size).to eq(0)
    expect(ActivateIntegrationsWorker.jobs.size).to eq(0)
  end

  [false, true].each do |require_final_charge_status|
    context "with require_final_charge_status: #{require_final_charge_status}" do
      def sync(purchase, require_final_charge_status)
        described_class.new(purchase.reload, require_final_charge_status:)
      end

      it "completes a cleanly captured purchase once" do
        _order, charge, (purchase, *) = build_cart
        fail_via_webhook(charge)
        Sidekiq::Worker.clear_all

        service = sync(purchase, require_final_charge_status)

        expect(service.perform).to be(true)
        expect(service.charge_outcome).to eq(:succeeded)
        expect(purchase.reload).to be_successful
        expect(ledger_cents([purchase])).to eq(charge.amount_cents)
        expect(access_count([purchase])).to eq(1)
        expect(SendChargeReceiptJob.jobs.size).to eq(1)
        expect(ActivateIntegrationsWorker.jobs.size).to eq(1)
      end

      it "completes every failed purchase of a cart" do
        _order, charge, purchases = build_cart(items: 3)
        fail_via_webhook(charge)

        expect(sync(purchases.first, require_final_charge_status).perform).to be(true)

        expect(purchases.map { _1.reload.purchase_state }).to eq(%w[successful successful successful])
        expect(ledger_cents(purchases)).to eq(charge.amount_cents)
        expect(access_count(purchases)).to eq(3)
      end

      it "completes a gift" do
        _order, charge, (gifter_purchase, *) = build_cart(gift: true)
        fail_via_webhook(charge)

        expect(sync(gifter_purchase, require_final_charge_status).perform).to be(true)

        gift = gifter_purchase.reload.gift_given
        expect(gift).to be_successful
        expect(gift.giftee_purchase).to be_gift_receiver_purchase_successful
        expect(gift.giftee_purchase.url_redirect).to be_present
      end

      it "completes a new membership with a subscription on the card saved from the intent" do
        # Tiered membership prices live on the default tier, not the product's price row.
        product = create(:membership_product, user: seller, price_cents: 5_00)
        _order, charge, (purchase, *) = build_cart(product:, line_item: { price_id: product.prices.alive.first.external_id, perceived_price_cents: 5_00 })
        provider[:intent] = { setup_future_usage: "off_session", customer: "cus_late" }
        provider[:charge] = {
          payment_method_details: { type: "card", card: { brand: "visa", last4: "4242", exp_month: 12, exp_year: 2040, fingerprint: "fp_late",
                                                          country: "US", checks: { address_postal_code_check: "pass" } } }
        }
        fail_via_webhook(charge)

        expect(sync(purchase, require_final_charge_status).perform).to be(true)

        expect(purchase.reload).to be_successful
        expect(purchase.subscription.credit_card).to eq(purchase.credit_card)
        expect(purchase.credit_card).to have_attributes(stripe_customer_id: "cus_late")
      end

      { "still processing" => "processing", "canceled" => "canceled" }.each do |label, status|
        it "leaves the purchase failed while the intent is #{label}" do
          _order, charge, (purchase, *) = build_cart
          fail_via_webhook(charge)
          provider[:pi_status] = status

          expect_refused([purchase], sync(purchase, require_final_charge_status))
        end
      end

      {
        "fully refunded" => ->(charge) { { refunded: true, amount_refunded: charge.amount_cents } },
        "partially refunded" => ->(_charge) { { amount_refunded: 3_00 } },
        "disputed" => ->(_charge) { { dispute: "dp_late" } },
        "captured for a different amount" => ->(charge) { { amount: charge.amount_cents - 1 } },
        "captured in a different currency" => ->(_charge) { { currency: "eur" } },
      }.each do |label, charge_override|
        it "leaves the purchase failed when Stripe reports the charge #{label}" do
          _order, charge, (purchase, *) = build_cart
          fail_via_webhook(charge)
          provider[:charge] = charge_override.call(charge)

          expect_refused([purchase], sync(purchase, require_final_charge_status))
        end
      end

      it "leaves failed purchases failed when their totals exceed what the charge captured" do
        _order, charge, (first, second) = build_cart(items: 2)
        charge.update!(amount_cents: second.total_transaction_cents, gumroad_amount_cents: second.total_transaction_amount_for_gumroad_cents)
        fail_via_webhook(charge)

        expect_refused([first, second], sync(first, require_final_charge_status))
      end

      it "does not re-fulfill a booked purchase that a stale failure overwrote" do
        _order, charge, (purchase, *) = build_cart
        deliver(charge, "payment_intent.succeeded")
        purchase.reload.update_columns(purchase_state: "failed")
        expect(purchase.balance_transactions.count).to eq(1)

        expect_refused([purchase], sync(purchase, require_final_charge_status))
      end

      it "leaves a failed upgrade purchase failed" do
        _order, charge, (purchase, *) = build_cart
        fail_via_webhook(charge)
        purchase.reload.update_flag!(:is_upgrade_purchase, true, true)

        expect_refused([purchase], sync(purchase, require_final_charge_status))
      end

      it "leaves a failed purchase on an existing subscription failed" do
        _order, charge, (purchase, *) = build_cart
        fail_via_webhook(charge)
        subscription = create(:subscription, link: purchase.link, deactivated_at: 1.day.ago)
        purchase.reload.update_columns(subscription_id: subscription.id)

        expect_refused([purchase], sync(purchase, require_final_charge_status))
        expect(subscription.reload.deactivated_at).to be_present
      end

      it "leaves a failed installment purchase failed" do
        product = create(:product, :with_installment_plan, user: seller)
        first_installment_cents = product.installment_plan.calculate_installment_payment_price_cents(product.price_cents)
        _order, charge, (purchase, *) = build_cart(product:, line_item: { pay_in_installments: true, perceived_price_cents: first_installment_cents })
        expect(purchase).to be_is_installment_payment
        fail_via_webhook(charge)

        expect_refused([purchase], sync(purchase, require_final_charge_status))
      end
    end
  end
end
