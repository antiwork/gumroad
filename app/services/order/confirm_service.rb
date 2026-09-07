# frozen_string_literal: true

# Finalizes the order once the charge SCA has been confirmed by the user on the front-end.
class Order::ConfirmService
  include Order::ResponseHelpers

  attr_reader :order, :params

  def initialize(order:, params:)
    @order = order
    @params = params
  end

  def perform
    retry_candidates = Order::OfferCodeRecoveryService.sanitize_retry_candidates(params[:retry_offer_codes])
    purchase_responses = {}
    offer_codes = {}
    failed_purchases = []

    charge_seller_groups_awaiting_setup_confirmation!

    order.purchases.each do |purchase|
      error = Purchase::ConfirmService.new(purchase:, params:).perform

      if error
        failed_purchases << purchase
        if purchase.offer_code.present?
          offer_codes[purchase.offer_code.code] ||= {}
          unless purchase.purchase_offer_code_discount&.once_per_cart?
            offer_codes[purchase.offer_code.code][purchase.link.unique_permalink] = { permalink: purchase.link.unique_permalink,
                                                                                      quantity: purchase.quantity,
                                                                                      discount_code: purchase.offer_code.code }
          end
        end
        purchase_responses[purchase.id] = error_response(error, purchase:)
      elsif purchase.pending_buyer_presentment_settlement?
        purchase_responses[purchase.id] = purchase_pending_processor_settlement_response(purchase)
      else
        purchase_responses[purchase.id] = purchase.purchase_response
      end
    end

    offer_codes = offer_codes.filter_map do |offer_code, products|
      response = { code: offer_code, result: OfferCodeDiscountComputingService.new(offer_code, products, buyer: order.purchaser).process }
      next if response[:result][:error_code].present?
      { code: response[:code], products: response[:result][:products_data].transform_values { _1[:discount] } }
    end
    recovered_offer_codes = Order::OfferCodeRecoveryService.new(order:, failed_purchases:).perform
    offer_codes = Order::OfferCodeRecoveryService.merge_responses(
      offer_codes,
      recovered_offer_codes,
      Order::OfferCodeRecoveryService.revalidate_retry_candidates(order:, candidates: retry_candidates)
    )

    return purchase_responses, offer_codes
  end

  private
    # A multi-seller cart with an India e-mandate pauses at a SetupIntent needing 3DS
    # (Order::ChargeService#register_india_mandate_for_off_session_cart!) — no PaymentIntent
    # exists yet for those seller groups. Now that the buyer has confirmed, create each
    # group's single combined off-session charge so the per-purchase confirms above finalize
    # a real charge; without it they would mark paid purchases successful with no money moved.
    def charge_seller_groups_awaiting_setup_confirmation!
      # A browser-reported Stripe error means the buyer failed authentication; the
      # per-purchase confirms fail everything via check_for_card_handling_error.
      return if CardParamsHelper.check_for_errors(params).present?

      order.purchases.group_by { |purchase| purchase.charge&.id }.each_value do |seller_purchases|
        pending = seller_purchases.select { |purchase| awaiting_charge_after_setup?(purchase) }
        next if pending.none?

        begin
          charge_setup_confirmed_purchases!(pending)
        rescue => e
          Rails.logger.error("Error charging confirmed setup intent for order #{order.id}: #{e.class} => #{e.message}")
          ErrorNotifier.notify(e, order_id: order.id)
          pending.each do |purchase|
            purchase.errors.add(:base, "There is a temporary problem, please try again (your card was not charged).") if purchase.errors.empty?
          end
        end
      end
    end

    def awaiting_charge_after_setup?(purchase)
      purchase.in_progress? &&
        purchase.errors.empty? &&
        purchase.charge.present? &&
        purchase.processor_setup_intent_id.present? &&
        purchase.processor_payment_intent.blank? &&
        purchase.stripe_transaction_id.blank? &&
        !purchase.free_purchase? &&
        !purchase.is_test_purchase? &&
        !purchase.is_free_trial_purchase? &&
        !purchase.is_preorder_authorization?
    end

    def charge_setup_confirmed_purchases!(purchases)
      reference_purchase = purchases.first
      reference_purchase.with_lock do
        # A concurrently retried confirm may have charged this group while we waited.
        next if reference_purchase.processor_payment_intent.present? || !reference_purchase.in_progress?

        charge_setup_confirmed_purchases_locked!(purchases)
      end
    end

    def charge_setup_confirmed_purchases_locked!(purchases)
      reference_purchase = purchases.first
      merchant_account = reference_purchase.merchant_account
      credit_card = reference_purchase.credit_card
      setup_intent_id = reference_purchase.processor_setup_intent_id
      setup_intent = credit_card.present? ? ChargeProcessor.get_setup_intent(merchant_account, setup_intent_id) : nil

      unless setup_intent&.succeeded?
        purchases.each do |purchase|
          purchase.error_code = PurchaseErrorCode::INDIA_CARD_MANDATE_MISSING
          purchase.errors.add(:base, "We couldn't authorize your card for this payment. Please try again or use a different payment method.")
        end
        return
      end

      chargeable = credit_card.to_chargeable(merchant_account:)
      # The card's json_data can hold another group's (or an older order's) intent; this
      # group's charge must reference the SetupIntent the buyer just confirmed for it.
      chargeable.stripe_setup_intent_id = setup_intent_id if chargeable.respond_to?(:stripe_setup_intent_id=)
      # The checkout request's prepared chargeable is gone; direct charges need the payment
      # method cloned to the connected account again before charging.
      chargeable.prepare!

      charge = Charge::CreateService.new(
        order:,
        seller: reference_purchase.seller,
        merchant_account:,
        chargeable:,
        purchases:,
        amount_cents: purchases.sum(&:total_transaction_cents),
        gumroad_amount_cents: purchases.sum(&:total_transaction_amount_for_gumroad_cents),
        setup_future_charges: false,
        off_session: true,
        statement_description: reference_purchase.seller.name_or_username,
        # The confirmed SetupIntent already carries the mandate; the charge references it
        # through the chargeable instead of asking Stripe to mint new terms off-session.
        mandate_options: nil,
        params: {},
      ).perform

      charge_intent = charge.charge_intent
      # On a nil intent Charge::CreateService already added buyer-facing errors to the
      # purchases, which fails them in the per-purchase confirms.
      return if charge_intent.blank?

      # Renewals resolve the e-mandate from the last charge on the card; keep only this
      # charge's intent so a stale SetupIntent from another account cannot shadow it.
      credit_card.update!(json_data: { "stripe_payment_intent_id" => charge_intent.id }) if credit_card.requires_mandate?
      return unless charge_intent.is_a?(StripeChargeIntent)

      purchases.each do |purchase|
        purchase.create_processor_payment_intent!(intent_id: charge_intent.id)
      end
    end
end
