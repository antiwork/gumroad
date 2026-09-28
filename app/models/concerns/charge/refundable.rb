# frozen_string_literal: true

module Charge::Refundable
  extend ActiveSupport::Concern

  EXTERNAL_REFUND_ALERT = "Stripe refund created outside the app"
  # Read of a refund whose seller legs cannot be paired: only its issued amount is used, and no
  # seller balance changes.
  UnpairedExternalRefund = Struct.new(:refund, :flow_of_funds, :charge)

  # A refund reached a terminal unsuccessful status after Stripe had accepted it.
  # "failed" means the buyer's bank returned an asynchronous bank-transfer refund
  # (iDEAL, Bancontact, ACH) days after creation, or that an asynchronous wallet refund
  # (Alipay, which settles in up to five minutes) did not complete; "canceled" means a pending refund
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
      unless refunded_amount_cents > 0 && refunded_amount_cents <= expected_refunded_amount_cents
        ErrorNotifier.notify(EXTERNAL_REFUND_ALERT, stripe_refund_id:, stripe_charge_id:, refunded_amount_cents:,
                                                    expected_refunded_amount_cents:, recorded: false)
        return
      end

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

      processor = StripeChargeProcessor.new
      merchant_account = refundable.merchant_account
      transfer_outcome = nil
      begin
        charge_refund = processor.get_refund(stripe_refund_id, merchant_account:, for_external_refund: true)
      rescue StripeChargeProcessor::UnmatchedApplicationFeeRefundError
        stripe_refund = Stripe::Refund.retrieve(id: stripe_refund_id, expand: %w[balance_transaction])
        # If the seller's transfer was reversed at all, the seller may have paid, so the debit is not
        # Gumroad's to forgive. A reversal made apart from the refund cannot be matched to it.
        transfer_outcome = seller_transfer_reversed?(stripe_refund) ? :reversal_unpaired : :fee_refund_unpaired
        charge_refund = UnpairedExternalRefund.new(stripe_refund, unpaired_external_refund_flow_of_funds(stripe_refund), nil)
      end
      purchases = refundable.charged_purchases.select { _1.successful? && !_1.stripe_refunded? }.sort_by(&:id)
      unrecorded = []
      blocked_purchase_ids = []
      refused_purchase_ids = []
      flow_of_funds_for = lambda do |purchase, refund|
        next refund.flow_of_funds unless purchase.is_part_of_combined_charge?

        purchase.send(:build_flow_of_funds_from_combined_charge, refund.flow_of_funds)
      end
      refunded_purchases = ApplicationRecord.transaction do
        # Lock every purchase (id order, as Charge#refund_and_save! does) before re-checking for
        # an app-side Refund row: an app refund's uncommitted transaction holds these locks, so
        # the re-check sees its row. It also serializes redeliveries of this webhook.
        purchases.each { _1.reload.lock! }
        unrecorded = purchases.reject do |purchase|
          Refund.where(processor_refund_id: stripe_refund_id, purchase_id: purchase.id).exists? || purchase.stripe_refunded?
        end
        next [] if unrecorded.empty?

        # Book the refund for every purchase or for none: the reversal takes the seller's money for the
        # whole charge, and a partial booking would stay partial on every redelivery.
        blocked_purchase_ids = unrecorded.reject { _1.refund_recordable_from?(flow_of_funds_for.(_1, charge_refund)) }.map(&:id)
        next [] if blocked_purchase_ids.any?

        if charge_refund.is_a?(StripeChargeRefund) && charge_refund.charge[:destination].present? &&
            merchant_account&.holder_of_funds == HolderOfFunds::STRIPE
          # A won dispute already reversed the transfer and sent the seller's share back in a separate
          # transfer, which cannot be reversed safely here. The charge-level reversal cannot be split
          # either, so every purchase on the charge is recorded for reconciliation.
          if unrecorded.any? { _1.chargedback? && _1.chargeback_reversed }
            transfer_outcome = :dispute_won
          else
            charge_refund, transfer_outcome = processor.reverse_transfer_for_external_refund(charge_refund, merchant_account:)
          end
        end
        # An unpaired refund is still booked, so the sale shows as refunded, but it changes no seller
        # balance: its seller legs could belong to a different refund on the charge.
        gumroad_funded = %i[not_reversible fee_refund_unpaired].include?(transfer_outcome)
        balance_reconciliation_needed = %i[reversal_unpaired dispute_won].include?(transfer_outcome)

        booked = unrecorded.select do |purchase|
          purchase.refund_purchase!(flow_of_funds_for.(purchase, charge_refund), GUMROAD_ADMIN_ID, charge_refund.refund,
                                    event.extras[:refund_reason] == "fraudulent",
                                    gumroad_funded:, balance_reconciliation_needed:)
        end
        # refund_purchase! can refuse a purchase the check above passed; a partial booking would stay
        # partial on every redelivery, so book none.
        refused_purchase_ids = (unrecorded - booked).map(&:id)
        raise ActiveRecord::Rollback if refused_purchase_ids.any?

        booked
      end || []
      return if unrecorded.empty?

      alert_context = { stripe_refund_id:, stripe_charge_id:, refunded_amount_cents:, transfer_outcome:,
                        refunded_purchase_ids: refunded_purchases.map(&:id),
                        unrecorded_purchase_ids: (unrecorded - refunded_purchases).map(&:id), blocked_purchase_ids:,
                        refused_purchase_ids: }
      notify_external_refund_alert(EXTERNAL_REFUND_ALERT, **alert_context, recorded: refunded_purchases.size == unrecorded.size)
      if refused_purchase_ids.any?
        if %i[reversed_by_gumroad reversed_by_stripe].include?(transfer_outcome)
          notify_external_refund_alert("Seller transfer reversed for a refund created outside the app, but the refund was not booked: reconcile the seller balance", **alert_context)
        end
      elsif transfer_outcome == :not_reversible
        notify_external_refund_alert("Refund created outside the app booked as Gumroad-funded: seller transfer not reversible", **alert_context)
      elsif transfer_outcome == :fee_refund_unpaired
        notify_external_refund_alert("Refund created outside the app booked as Gumroad-funded: application fee refund cannot be paired", **alert_context)
      elsif %i[reversal_unpaired dispute_won].include?(transfer_outcome)
        notify_external_refund_alert("Refund created outside the app booked without a seller balance change: reconcile the seller balance", **alert_context)
      end

      refunded_purchases.each do |purchase|
        if event.extras[:refund_reason] == "fraudulent"
          ContactingCreatorMailer.purchase_refunded_for_fraud(purchase.id).deliver_later
        else
          ContactingCreatorMailer.purchase_refunded(purchase.id).deliver_later
        end
      end
    end
  rescue StripeChargeProcessor::UnmatchedApplicationFeeRefundError
    ErrorNotifier.notify(EXTERNAL_REFUND_ALERT, stripe_refund_id:, stripe_charge_id:, refunded_amount_cents:,
                                                transfer_outcome: :fee_refund_unpaired, recorded: false)
  rescue StandardError => error
    if stripe_charge_id.present?
      ErrorNotifier.notify(EXTERNAL_REFUND_ALERT, stripe_refund_id:, stripe_charge_id:, refunded_amount_cents:,
                                                  transfer_outcome: transfer_outcome || :unknown,
                                                  recording_outcome: :unknown, error_class: error.class.name)
    end
    raise
  end

  # The settled amount comes from the refund's balance transaction, in the platform currency; the
  # issued amount is in the charge currency, which on a buyer-currency charge is the buyer's.
  private def unpaired_external_refund_flow_of_funds(stripe_refund)
    issued_amount = FlowOfFunds::Amount.new(currency: stripe_refund[:currency], cents: -stripe_refund[:amount])
    balance_transaction = stripe_refund[:balance_transaction]
    settled_amount = if balance_transaction.is_a?(Stripe::StripeObject)
      FlowOfFunds::Amount.new(currency: balance_transaction[:currency], cents: balance_transaction[:amount])
    end
    FlowOfFunds.new(issued_amount:, settled_amount:, gumroad_amount: settled_amount || issued_amount)
  end

  private def seller_transfer_reversed?(stripe_refund)
    return true if stripe_refund[:transfer_reversal].present?

    transfer_id = Stripe::Charge.retrieve(stripe_refund[:charge])[:transfer]
    transfer_id.present? && Stripe::Transfer.retrieve(transfer_id)[:amount_reversed].to_i.positive?
  end

  # The refund is committed by the time these alerts run, and a redelivered event returns early on
  # the existing Refund rows, so a failing alert must not skip the creator emails queued after it.
  private def notify_external_refund_alert(message, **context)
    ErrorNotifier.notify(message, **context)
  rescue StandardError => error
    Rails.logger.warn(
      "External refund alert failed: #{error.class}: #{error.message} " \
      "message: #{message.inspect} " \
      "stripe_refund_id: #{context[:stripe_refund_id].inspect} " \
      "stripe_charge_id: #{context[:stripe_charge_id].inspect} " \
      "refunded_amount_cents: #{context[:refunded_amount_cents].inspect} " \
      "transfer_outcome: #{context[:transfer_outcome].inspect} " \
      "refunded_purchase_ids: #{context[:refunded_purchase_ids].inspect} " \
      "unrecorded_purchase_ids: #{context[:unrecorded_purchase_ids].inspect} " \
      "blocked_purchase_ids: #{context[:blocked_purchase_ids].inspect} " \
      "refused_purchase_ids: #{context[:refused_purchase_ids].inspect} " \
      "recorded: #{context[:recorded].inspect}"
    )
  end
end
