# frozen_string_literal: true

module Purchase::DisputeWinCredits
  extend ActiveSupport::Concern

  def create_credit_for_dispute_won_for_affiliate!(flow_of_funds, amount_cents: 0)
    return if affiliate_credit_cents == 0 || amount_cents == 0

    affiliate_issued_amount = BalanceTransaction::Amount.create_issued_amount_for_affiliate(
        flow_of_funds:,
        issued_affiliate_cents: amount_cents
    )

    affiliate_holding_amount = BalanceTransaction::Amount.create_holding_amount_for_affiliate(
        flow_of_funds:,
        issued_affiliate_cents: amount_cents
    )

    Credit.create_for_dispute_won!(
        merchant_account: affiliate_merchant_account,
        user: affiliate_credit.affiliate_user,
        dispute: charge.present? ? charge.dispute : dispute,
        chargedback_purchase: self,
        balance_transaction_issued_amount: affiliate_issued_amount,
        balance_transaction_holding_amount: affiliate_holding_amount
    )
  end

  def create_credit_for_dispute_won_for_seller!(flow_of_funds, amount_cents:)
    return unless charged_using_gumroad_merchant_account?

    seller_issued_amount = BalanceTransaction::Amount.create_issued_amount_for_seller(
        flow_of_funds:,
        issued_net_cents: amount_cents
    )

    seller_holding_amount = BalanceTransaction::Amount.create_holding_amount_for_seller(
        flow_of_funds:,
        issued_net_cents: amount_cents
    )

    Credit.create_for_dispute_won!(
        merchant_account:,
        user: seller,
        dispute: charge.present? ? charge.dispute : dispute,
        chargedback_purchase: self,
        balance_transaction_issued_amount: seller_issued_amount,
        balance_transaction_holding_amount: seller_holding_amount
    )
  end

  def create_credit_for_dispute_won!(flow_of_funds)
    unless stripe_partially_refunded?
      # Short circuit for full refund, or dispute
      seller_disputed_cents = payment_cents - affiliate_credit_cents
      affiliate_disputed_cents = affiliate_credit_cents
    else
      disputed_fee_cents = ((fee_cents.to_f / price_cents.to_f) * amount_refundable_cents).floor
      seller_disputed_cents = amount_refundable_cents - disputed_fee_cents
      if affiliate_credit_cents == 0
        affiliate_disputed_cents = 0
      else
        affiliate_disputed_cents = ((affiliate.affiliate_basis_points / 10_000.0) * amount_refundable_cents).floor
        seller_disputed_cents = seller_disputed_cents - affiliate_disputed_cents
      end
    end
    create_credit_for_dispute_won_for_affiliate!(flow_of_funds, amount_cents: affiliate_disputed_cents)
    create_credit_for_dispute_won_for_seller!(flow_of_funds, amount_cents: seller_disputed_cents)
  end
end
