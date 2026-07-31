# frozen_string_literal: true

# Syncs the purchase status with Stripe/PayPal
class Purchase::SyncStatusWithChargeProcessorService
  # Charge statuses that count as success but are not final: the money may still settle or still
  # fail, so a purchase sitting behind one of these is waiting, not stuck.
  PENDING_CHARGE_STATUSES = %w[pending created approved].freeze

  attr_accessor :purchase, :mark_as_failed
  # Why the last #perform did not succeed, for callers that report on rows they could not heal:
  # :succeeded means the charge is genuinely good and the purchase still could not be finalized.
  # nil until #perform has actually consulted the processor.
  attr_reader :charge_outcome

  def initialize(purchase, mark_as_failed: false)
    @purchase = purchase
    @mark_as_failed = mark_as_failed
  end

  def perform
    return false unless purchase.in_progress? || purchase.failed?

    # Nothing below is idempotent — balance_transactions has no unique index on purchase_id — so
    # two callers finalizing the same row would credit the seller twice and re-send the receipt.
    # Every trigger (checkout, webhooks, SyncStuckPurchasesJob, the unbounded recovery pass) comes
    # through here, so holding the row for the whole read-then-write is what makes them exclusive.
    purchase.with_lock do
      # Re-read under the lock: whoever we queued behind may have just finalized this row.
      next false unless purchase.in_progress? || purchase.failed?

      if purchase.failed?
        purchase.update!(purchase_state: "in_progress")
        if purchase.is_gift_sender_purchase
          purchase.gift_given&.update!(state: "in_progress")
          purchase.gift_given&.giftee_purchase&.update!(purchase_state: "in_progress")
        end
      end

      charge = ChargeProcessor.get_or_search_charge(purchase)
      success_statuses = ChargeProcessor.charge_processor_success_statuses(purchase.charge_processor_id)
      charge_succeeded = charge && success_statuses.include?(charge.status) &&
                         !charge.try(:refunded) && !charge.try(:refunded?) && !charge.try(:disputed)
      @charge_outcome = classify(charge, success_statuses)

      if charge_succeeded && purchase.is_part_of_combined_charge? && charge.flow_of_funds.nil?
        # Transient unsettled state: the underlying combined Stripe charge succeeded but
        # `balance_transaction` (and therefore `flow_of_funds`) hasn't been produced yet.
        # Leave the purchase `in_progress` so a subsequent SyncStuckPurchasesJob run can
        # re-attempt once Stripe settles, rather than permanently failing a purchase whose
        # underlying charge actually succeeded.
        false
      elsif charge_succeeded
        purchase.flow_of_funds = if purchase.is_part_of_combined_charge?
          purchase.build_flow_of_funds_from_combined_charge(charge.flow_of_funds)
        else
          charge.flow_of_funds
        end
        purchase.stripe_transaction_id = charge.id unless purchase.stripe_transaction_id.present?
        purchase.charge.processor_transaction_id = charge.id if purchase.charge.present? && purchase.charge.processor_transaction_id.blank?
        purchase.merchant_account = purchase.send(:prepare_merchant_account, purchase.charge_processor_id) unless purchase.merchant_account.present?
        if purchase.balance_transactions.exists?
          purchase.mark_successful!
        else
          Purchase::MarkSuccessfulService.new(purchase).perform
        end
        true
      elsif charge.nil? && purchase.free_purchase?
        Purchase::MarkSuccessfulService.new(purchase).perform
        true
      else
        purchase.mark_failed! if mark_as_failed
        false
      end
    end
  rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
    # Another caller holds the row and is deciding this purchase's outcome right now. Failing it
    # here would contradict whatever they land on, so report and leave the row to them.
    ErrorNotifier.notify(e) { |report| report.add_metadata(:purchase, { id: purchase.id }) }
    false
  rescue StandardError => e
    ErrorNotifier.notify(e) { |report| report.add_metadata(:purchase, { id: purchase.id }) }
    purchase.mark_failed! if mark_as_failed
    false
  end

  private
    def classify(charge, success_statuses)
      return :missing if charge.nil?
      return :refunded if charge.try(:refunded) || charge.try(:refunded?)
      return :disputed if charge.try(:disputed)
      return :unsuccessful unless success_statuses.include?(charge.status)
      return :pending if charge.status.in?(PENDING_CHARGE_STATUSES)

      :succeeded
    end
end
