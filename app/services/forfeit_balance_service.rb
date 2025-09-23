# frozen_string_literal: true

class ForfeitBalanceService
  include CurrencyHelper

  attr_reader :user, :reason

  def initialize(user:, reason:)
    @user = user
    @reason = reason
  end

  def process
    return unless balance_amount_cents_to_forfeit > 0

    balances_to_forfeit.each(&:mark_forfeited!)

    balance_ids = balances_to_forfeit.ids.join(", ")
    user.comments.create!(
      author_id: GUMROAD_ADMIN_ID,
      comment_type: Comment::COMMENT_TYPE_BALANCE_FORFEITED,
      content: "Balance of #{balance_amount_formatted} has been forfeited. Reason: #{reason_comment}. Balance IDs: #{balance_ids}"
    )
  end

  def balance_amount_formatted
    formatted_dollar_amount(balance_amount_cents_to_forfeit)
  end

  def balance_amount_cents_to_forfeit
    @_balance_amount_cents_to_forfeit ||= balances_to_forfeit.sum(:amount_cents)
  end

  private
    def reason_comment
      case reason
      when :account_closure
        "Account closed"
      when :country_change
        "Country changed"
      when :payout_method_change
        "Payout method changed"
      end
    end

    def balances_to_forfeit
      @_balances_to_forfeit ||= send("balances_to_forfeit_on_#{reason}")
    end

    def balances_to_forfeit_on_account_closure
      user.unpaid_balances
    end

    # Forfeiting is only needed if balance is in a Gumroad-controlled Stripe account
    def balances_to_forfeit_on_country_change
      user.unpaid_balances.where.not(merchant_account_id: [
                                       MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                                       MerchantAccount.gumroad(PaypalChargeProcessor.charge_processor_id),
                                       MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id)
                                     ])
    end

    # Forfeiting is only needed if balance is in a Gumroad-controlled Stripe account
    def balances_to_forfeit_on_payout_method_change
      balances_to_forfeit_on_country_change
    end
end
