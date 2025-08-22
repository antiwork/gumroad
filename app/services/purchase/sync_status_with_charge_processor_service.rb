# frozen_string_literal: true

# Syncs the purchase status with Stripe/PayPal
class Purchase::SyncStatusWithChargeProcessorService
  attr_accessor :purchase, :mark_as_failed

  def initialize(purchase, mark_as_failed: false)
    @purchase = purchase
    @mark_as_failed = mark_as_failed
  end

  def perform
    return false unless purchase.in_progress? || purchase.failed?

    ActiveRecord::Base.transaction do
      if purchase.failed?
        purchase.update!(purchase_state: "in_progress")
        if purchase.is_gift_sender_purchase
          purchase.gift_given&.update!(state: "in_progress")
          purchase.gift_given&.giftee_purchase&.update!(purchase_state: "in_progress")
        end
      end

      charge = ChargeProcessor.get_or_search_charge(purchase)
      success_statuses = ChargeProcessor.charge_processor_success_statuses(purchase.charge_processor_id)
      if charge && success_statuses.include?(charge.status) && !charge.try(:refunded) && !charge.try(:refunded?) && !charge.try(:disputed)
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
  rescue StandardError => e
    Bugsnag.notify(e) { |report| report.add_metadata(:purchase, { id: purchase.id }) }
    purchase.mark_failed! if mark_as_failed
    false
  end
end
