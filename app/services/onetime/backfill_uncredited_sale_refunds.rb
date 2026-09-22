# frozen_string_literal: true

# Books the Refund row for a refund the processor issued but the local write rolled back with no
# retry (the charge is already refunded there). Record-only: the purchase never ran the success path.
#
#   Onetime::BackfillUncreditedSaleRefunds.process(dry_run: true, refunds: { "purchase external id" => "re_..." })
class Onetime::BackfillUncreditedSaleRefunds
  def self.process(refunds:, dry_run: true)
    rows = refunds.map do |purchase_external_id, processor_refund_id|
      new(purchase_external_id:, processor_refund_id:, dry_run:).process
    end
    { dry_run:, rows: }
  end

  def initialize(purchase_external_id:, processor_refund_id:, dry_run: true)
    @purchase_external_id = purchase_external_id
    @processor_refund_id = processor_refund_id
    @dry_run = dry_run
  end

  def process
    purchase = Purchase.find_by_external_id!(@purchase_external_id)
    verify_bookable!(purchase)

    charge_refund = StripeChargeProcessor.new.get_refund(@processor_refund_id, merchant_account: purchase.merchant_account)
    stripe_refund = charge_refund.refund
    unless stripe_refund&.status == "succeeded"
      raise ArgumentError, "Processor refund #{@processor_refund_id} is not a succeeded refund"
    end
    unless charge_refund.charge_id == purchase.stripe_transaction_id
      raise ArgumentError, "Processor refund #{@processor_refund_id} belongs to charge #{charge_refund.charge_id}, not to purchase #{@purchase_external_id}"
    end

    reported = {
      purchase_id: purchase.id,
      purchase_external_id: @purchase_external_id,
      purchase_number: purchase.external_id_numeric,
      processor_refund_id: @processor_refund_id,
      refunded_cents: charge_refund.flow_of_funds.issued_amount.cents.abs,
    }
    return reported.merge(status: :dry_run) if @dry_run

    purchase.refund_purchase!(charge_refund.flow_of_funds, GUMROAD_ADMIN_ID, stripe_refund, false,
                              note: "Backfill: refunded at #{purchase.charge_processor_id.titleize} with no local refund record")
    purchase.reload
    refund = purchase.refunds.order(:id).last
    raise "No refund was recorded for purchase #{purchase.id}" if refund.blank?
    unless refund.balance_transactions.none? && purchase.purchase_refund_balance_id.nil?
      raise "Refund #{refund.id} wrote a seller debit; expected a record-only booking"
    end

    Rails.logger.info("[BackfillUncreditedSaleRefunds] #{reported.merge(refund_id: refund.id).to_json}")
    reported.merge(status: :applied, refund_id: refund.id)
  end

  private
    # Every condition here is the stranded state itself. Anything else is a purchase whose
    # refund belongs to a different repair (or to a retry of refund_and_save!).
    def verify_bookable!(purchase)
      if purchase.seller_credited_for_sale?
        raise ArgumentError, "Purchase #{@purchase_external_id} was credited to the seller; booking its refund here would write a seller debit"
      end
      raise ArgumentError, "Purchase #{@purchase_external_id} has no charge" if purchase.stripe_transaction_id.blank?
      raise ArgumentError, "Purchase #{@purchase_external_id} already has a refund record" if purchase.refunds.exists?
      raise ArgumentError, "Purchase #{@purchase_external_id} is already marked refunded" if purchase.stripe_refunded
      raise ArgumentError, "Purchase #{@purchase_external_id} has nothing left to refund" if purchase.amount_refundable_cents <= 0
    end
end
