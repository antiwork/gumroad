# frozen_string_literal: true

require "spec_helper"

describe Purchase::FinalizeConfirmedChargeService, "after a missing-settlement deferral" do
  include ClientConfirmedLateSuccessHelpers

  def defer_then_fail_stale(mode:, gift: false)
    order, charge, (purchase, *) = build_cart(mode:, gift:)
    provider[:charge] = { balance_transaction: nil }
    Order::FinalizeConfirmedChargeService.new(order: Order.find(order.id)).perform
    purchase.reload
    expect(purchase).to be_in_progress
    expect(purchase.stripe_transaction_id).to eq("ch_late_#{charge.id}")
    expect([purchase.balance_transactions.count, access_count([purchase])]).to eq([0, 0])
    expect(FinalizeBuyerPresentmentChargeJob.jobs.size).to eq(1)

    fail_via_webhook(charge)
    expect(purchase.reload).to be_failed
    # Queues are never cleared, so these zeros make every later count cover the whole sequence.
    expect([SendChargeReceiptJob.jobs.size, ActivateIntegrationsWorker.jobs.size]).to eq([0, 0])
    provider[:charge] = {}
    [order, charge, purchase]
  end

  # Counts enqueues, not deliveries. Every order-level finalize enqueues SendChargeReceiptJob again
  # while receipt_sent is unset (the jobs are not executed here), so replays compare the rest.
  def booking(purchase)
    purchase.reload
    { state: purchase.purchase_state, ledger_rows: purchase.balance_transactions.count, access: access_count([purchase]),
      receipts: SendChargeReceiptJob.jobs.size, integrations: ActivateIntegrationsWorker.jobs.size }
  end

  { destination_charge: 1, connect_direct: 0 }.each do |mode, ledger_rows|
    context "with #{mode} funds" do
      it "stays failed through the settlement job, then books once on the settled webhook success" do
        _order, charge, purchase = defer_then_fail_stale(mode:)
        FinalizeBuyerPresentmentChargeJob.drain
        expect(purchase.reload).to be_failed

        deliver(charge, "payment_intent.succeeded")

        expect(booking(purchase)).to eq(state: "successful", ledger_rows:, access: 1, receipts: 1, integrations: 1)
        expect(purchase.stripe_transaction_id).to eq("ch_late_#{charge.id}")
        expect(ledger_cents([purchase])).to eq(charge.amount_cents) if ledger_rows == 1

        expect do
          deliver(charge, "payment_intent.succeeded")
          Purchase::SyncStatusWithChargeProcessorService.new(purchase.reload, require_final_charge_status: true).perform
          Order::FinalizeConfirmedChargeService.new(order: purchase.order).perform
        end.not_to change { booking(purchase).except(:receipts) }
      end

      [false, true].each do |require_final_charge_status|
        it "books once through manual sync (require_final_charge_status: #{require_final_charge_status})" do
          _order, charge, purchase = defer_then_fail_stale(mode:)

          service = Purchase::SyncStatusWithChargeProcessorService.new(purchase.reload, require_final_charge_status:)

          expect(service.perform).to be(true)
          expect(booking(purchase)).to eq(state: "successful", ledger_rows:, access: 1, receipts: 1, integrations: 1)
          expect { Purchase::SyncStatusWithChargeProcessorService.new(purchase.reload, require_final_charge_status:).perform }
            .not_to change { booking(purchase).except(:receipts) }
          expect(charge.reload.processor_transaction_id).to eq("ch_late_#{charge.id}")
        end
      end

      it "books once when the finalizer is called directly with the settled intent" do
        _order, charge, purchase = defer_then_fail_stale(mode:)
        charge_intent = ChargeProcessor.get_charge_intent(charge.merchant_account, charge.stripe_payment_intent_id)

        expect(described_class.new(purchase: purchase.reload, charge_intent:).perform).to be_nil
        expect(booking(purchase)).to eq(state: "successful", ledger_rows:, access: 1, receipts: 0, integrations: 1)
        expect(described_class.new(purchase: purchase.reload, charge_intent:).perform).to be_nil
        expect(booking(purchase)).to eq(state: "successful", ledger_rows:, access: 1, receipts: 0, integrations: 1)
      end

      it "leaves the purchase failed when its saved charge id is not this intent's charge" do
        _order, charge, purchase = defer_then_fail_stale(mode:)
        purchase.update_columns(stripe_transaction_id: "ch_late_other")

        deliver(charge, "payment_intent.succeeded")
        Purchase::SyncStatusWithChargeProcessorService.new(purchase.reload).perform

        expect(booking(purchase)).to eq(state: "failed", ledger_rows: 0, access: 0, receipts: 0, integrations: 0)
        expect(purchase.stripe_transaction_id).to eq("ch_late_other")
      end

      it "still waits, not books, when the settled success still has no settlement data" do
        _order, charge, purchase = defer_then_fail_stale(mode:)
        provider[:charge] = { balance_transaction: nil }

        deliver(charge, "payment_intent.succeeded")

        expect(booking(purchase)).to eq(state: "in_progress", ledger_rows: 0, access: 0, receipts: 0, integrations: 0)
        # One from the first deferral, one from this one.
        expect(FinalizeBuyerPresentmentChargeJob.jobs.size).to eq(2)
        provider[:charge] = {}
        FinalizeBuyerPresentmentChargeJob.drain
        expect(booking(purchase)).to include(state: "successful", ledger_rows:, access: 1, integrations: 1)
      end
    end
  end

  it "completes a deferred gift after the stale failure failed its legs" do
    _order, charge, purchase = defer_then_fail_stale(mode: :destination_charge, gift: true)
    gift = purchase.gift_given
    expect(gift.reload).to be_failed

    deliver(charge, "payment_intent.succeeded")

    giftee_purchase = gift.giftee_purchase
    gift_booking = -> { [purchase.reload.purchase_state, purchase.balance_transactions.count, access_count([purchase, giftee_purchase]), ActivateIntegrationsWorker.jobs.size] }
    expect(gift_booking.call).to eq(["successful", 1, 1, 1])
    expect(gift.reload).to be_successful
    expect(giftee_purchase.reload).to be_gift_receiver_purchase_successful
    expect(giftee_purchase.url_redirect).to be_present

    expect do
      deliver(charge, "payment_intent.succeeded")
      Purchase::SyncStatusWithChargeProcessorService.new(purchase.reload, require_final_charge_status: true).perform
    end.not_to change { gift_booking.call }
  end

  it "leaves a deferred purchase that also failed for its own reason failed" do
    _order, charge, purchase = defer_then_fail_stale(mode: :destination_charge)
    purchase.update_columns(error_code: PurchaseErrorCode::PPP_CARD_COUNTRY_NOT_MATCHING)

    deliver(charge, "payment_intent.succeeded")

    expect(booking(purchase)).to include(state: "failed", ledger_rows: 0, access: 0)
  end

  it "leaves a Connect-direct purchase that was booked before a stale failure failed, without regranting access" do
    _order, charge, (purchase, *) = build_cart(mode: :connect_direct)
    deliver(charge, "payment_intent.succeeded")
    expect(purchase.reload).to be_successful
    purchase.update_columns(purchase_state: "failed")
    before = booking(purchase)
    expect(before).to include(state: "failed", ledger_rows: 0, access: 1, integrations: 1)

    deliver(charge, "payment_intent.succeeded")
    Purchase::SyncStatusWithChargeProcessorService.new(purchase.reload).perform

    expect(booking(purchase)).to eq(before)
  end
end
