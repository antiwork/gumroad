# frozen_string_literal: true

module Charge::Refundable
  extend ActiveSupport::Concern

  def handle_event_refund_updated!(event)
    stripe_refund_id = event.refund_id

    db_refunds = Refund.where(processor_refund_id: stripe_refund_id)
    if db_refunds.present?
      db_refunds.each do |db_refund|
        db_refund.status = event.extras[:refund_status]
        db_refund.save!
      end
    else
      return unless event.extras[:refund_status] == "succeeded"

      stripe_charge_id = event.charge_id
      refundable = Charge.find_by(processor_transaction_id: stripe_charge_id) || Purchase.find_by(stripe_transaction_id: stripe_charge_id)
      return unless refundable.present?
      return unless event.extras[:refunded_amount_cents] == refundable.refundable_amount_cents

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
