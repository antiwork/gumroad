# frozen_string_literal: true

module Charge::Refundable
  extend ActiveSupport::Concern

  # A refund reached a terminal unsuccessful status after Stripe had accepted it.
  # "failed" means the buyer's bank returned an asynchronous bank-transfer refund
  # (iDEAL, Bancontact, ACH) days after creation; "canceled" means a pending refund
  # was canceled before completing. Either way the money is back in our Stripe
  # balance and the buyer did NOT receive it. Per the reversal-depth decision on
  # PR #5779: automatically reverse the balance debits and refunded flags (the
  # unambiguous money facts), alert a human for everything that needs judgment
  # (buyer communication, re-refund, subscription/payout follow-up).
  def handle_event_refund_failed!(event)
    db_refunds = Refund.where(processor_refund_id: event.refund_id)
    if db_refunds.blank?
      # A failure for a refund we have no record of: alert rather than ignore, because
      # unlike an unmatched refund.updated (usually a seller's own non-Gumroad refund on
      # a connect endpoint, filtered upstream), an unmatched FAILURE on our platform
      # endpoint means money moved back to us with no book entry to reconcile against.
      ErrorNotifier.notify("Received refund.failed for a refund with no Gumroad record — " \
                           "Stripe refund #{event.refund_id}, charge #{event.charge_id}, " \
                           "event #{event.charge_event_id}.")
      return
    end

    # Persist Stripe's actual terminal status ("failed" or "canceled") rather than
    # coercing everything to "failed"; the reversal handling is identical for both.
    failure_status = event.extras&.dig(:refund_status)
    failure_status = "failed" unless Refund::TERMINAL_FAILURE_STATUSES.include?(failure_status)
    db_refunds.each do |db_refund|
      Purchase::HandleFailedRefundService.new(refund: db_refund, failure_status:).perform
    end
  end

  def handle_event_refund_updated!(event)
    stripe_refund_id = event.refund_id

    db_refunds = Refund.where(processor_refund_id: stripe_refund_id)
    if db_refunds.present?
      db_refunds.each do |db_refund|
        # Take the same row lock the failure handler takes before checking or writing
        # the refund's status. Without it, a stale refund.updated racing the failure
        # handler could pass the guard below on a pre-failure snapshot and then save,
        # resurrecting the failed status — and because reading the reversal marker
        # touches json_data, the save would also write back the stale (unset) marker,
        # letting a redelivered refund.failed reverse the same money twice.
        db_refund.with_lock do
          # Never let a late or re-delivered refund.updated (e.g. a stale "pending"
          # retried by Stripe after the failure landed) overwrite a terminal failure
          # status ("failed"/"canceled"): the failure handling already reversed the
          # balance debits, and resurrecting the status would make the bounced refund
          # count as delivered money again.
          next if db_refund.terminally_failed? || db_refund.balance_reversed_on_failure

          db_refund.status = event.extras[:refund_status]
          db_refund.save!
        end
      end
    else
      return unless event.extras[:refund_status] == "succeeded"

      stripe_charge_id = event.charge_id
      refundable = Charge.find_by(processor_transaction_id: stripe_charge_id) || Purchase.find_by(stripe_transaction_id: stripe_charge_id)
      return unless refundable.present?
      # Stripe reports refunded_amount_cents in the charge currency, which for
      # buyer-presentment charges is the buyer's currency, not canonical USD.
      expected_refunded_amount_cents = refundable.presentment_refundable_amount_cents || refundable.refundable_amount_cents
      refunded_amount_cents = event.extras[:refunded_amount_cents].to_i
      return unless refunded_amount_cents > 0 && refunded_amount_cents <= expected_refunded_amount_cents

      # A partial charge-level refund on a combined charge with multiple purchases
      # cannot be reliably attributed: a proportional split across all purchases may
      # not match the intent of a dashboard refund aimed at a single purchase. Surface
      # it loudly instead of recording a possibly-wrong split or dropping it silently.
      if refunded_amount_cents < expected_refunded_amount_cents && refundable.charged_purchases.size > 1
        ErrorNotifier.notify(
          "Processor-initiated partial refund on a combined charge with multiple purchases cannot be attributed automatically",
          context: {
            stripe_refund_id:,
            stripe_charge_id:,
            refundable_type: refundable.class.name,
            refundable_id: refundable.id,
            refunded_amount_cents:,
            expected_refunded_amount_cents:,
          }
        )
        return
      end

      charge_refund = StripeChargeProcessor.new.get_refund(stripe_refund_id, merchant_account: refundable.merchant_account)
      refundable.charged_purchases.each do |purchase|
        next if !purchase.successful? || purchase.stripe_refunded?
        flow_of_funds = if purchase.is_part_of_combined_charge?
          purchase.send(:build_flow_of_funds_from_combined_charge, charge_refund.flow_of_funds)
        else
          charge_refund.flow_of_funds
        end
        refunded = purchase.refund_purchase!(flow_of_funds, GUMROAD_ADMIN_ID, charge_refund.refund, event.extras[:refund_reason] == "fraudulent")
        next unless refunded
        if event.extras[:refund_reason] == "fraudulent"
          ContactingCreatorMailer.purchase_refunded_for_fraud(purchase.id).deliver_later
        else
          ContactingCreatorMailer.purchase_refunded(purchase.id).deliver_later
        end
      end
    end
  end
end
