# frozen_string_literal: true

class Admin::Compliance::CardsController < Admin::BaseController
  FRAUD_REFUND_LOOKBACK_PERIOD = 6.months

  def refund
    if params[:stripe_fingerprint].blank?
      render json: { success: false }
    else
      purchase_ids = Purchase
        .not_chargedback_or_chargedback_reversed
        .paid
        .where(stripe_fingerprint: params[:stripe_fingerprint])
        .where("created_at >= ?", FRAUD_REFUND_LOOKBACK_PERIOD.ago)
        .ids
      purchase_ids.each do |purchase_id|
        RefundPurchaseWorker.perform_async(purchase_id, current_user.id, Refund::FRAUD)
      end

      render json: { success: true }
    end
  end
end
