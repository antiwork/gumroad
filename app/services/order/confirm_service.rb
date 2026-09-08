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
      error =
        if setup_charge_results.key?(purchase.id)
          result = setup_charge_results[purchase.id]
          if result == :pending
            # Same shape as Order::FinalizeConfirmedChargeService#response_for: the debit is
            # scheduled (India intents stay `processing` for hours), so the buyer must see a
            # pending outcome, never a resubmittable failure.
            purchase_responses[purchase.id] = { success: true, processing: true, permalink: purchase.link.unique_permalink }
            next
          end
          if result.is_a?(Hash) && result[:awaiting_setup]
            purchase_responses[purchase.id] = result[:awaiting_setup]
            next
          end
          result
        else
          Purchase::ConfirmService.new(purchase:, params:).perform
        end

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
    # Per-purchase finalize results from the setup-confirmed charge path, keyed by purchase id:
    # nil (finalized successful), :pending (debit scheduled/processing), or a buyer-facing error.
    def setup_charge_results
      @setup_charge_results ||= {}
    end

    # A multi-seller cart with an India e-mandate pauses at a SetupIntent needing 3DS
    # (Order::ChargeService#register_india_mandate_for_off_session_cart!) — no PaymentIntent
    # exists yet for those seller groups. Now that the buyer has confirmed, create each
    # group's single combined off-session charge and finalize its purchases from the created
    # intent; without it they would be marked successful with no money moved.
    def charge_seller_groups_awaiting_setup_confirmation!
      # A browser-reported Stripe error means the buyer failed authentication; the
      # per-purchase confirms fail everything via check_for_card_handling_error.
      return if CardParamsHelper.check_for_errors(params).present?

      order.purchases.group_by { |purchase| purchase.charge&.id }.each_value do |seller_purchases|
        pending = seller_purchases.select { |purchase| awaiting_charge_after_setup?(purchase) }
        charged = seller_purchases.select { |purchase| charged_after_setup_awaiting_finalization?(purchase) }
        next if pending.none? && charged.none?

        begin
          if pending.any?
            charge_setup_confirmed_purchases!(pending)
          else
            # A retried confirm: the group's off-session charge already exists, and India debits
            # stay `processing` inside Stripe's 26h window. Purchase::ConfirmService would
            # re-confirm the intent, which Stripe rejects for a processing intent whose debit is
            # already scheduled — finalize from a retrieve-only intent instead.
            finalize_setup_charged_purchases!(charged)
          end
        rescue => e
          Rails.logger.error("Error charging confirmed setup intent for order #{order.id}: #{e.class} => #{e.message}")
          ErrorNotifier.notify(e, order_id: order.id)
          (pending + charged).each do |purchase|
            if purchase.processor_payment_intent.present?
              # The charge exists, so its debit may already be scheduled; failing the purchase
              # (or letting Purchase::ConfirmService re-confirm the intent) could lose a payment
              # that is still going to capture. Report processing and let webhooks finish it.
              setup_charge_results[purchase.id] = :pending unless setup_charge_results.key?(purchase.id)
            elsif purchase.errors.empty?
              purchase.errors.add(:base, "There is a temporary problem, please try again (your card was not charged).")
            end
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

    # A purchase whose group's off-session charge already exists (created by this path, or
    # synchronously by Order::ChargeService when the card's mandate needed no pause — those
    # rows carry stripe_status `processing` but no SetupIntent id) and that is still
    # in_progress — typically because the intent is `processing`. It must be finalized from a
    # retrieved intent, never re-confirmed: Stripe rejects confirming a processing intent
    # whose debit is already scheduled, which would fail a purchase that is going to capture.
    def charged_after_setup_awaiting_finalization?(purchase)
      purchase.in_progress? &&
        purchase.errors.empty? &&
        (purchase.processor_setup_intent_id.present? || purchase.stripe_status == StripeIntentStatus::PROCESSING) &&
        purchase.processor_payment_intent.present? &&
        purchase.stripe_transaction_id.blank? &&
        !purchase.free_purchase? &&
        !purchase.is_test_purchase? &&
        !purchase.is_free_trial_purchase? &&
        !purchase.is_preorder_authorization?
    end

    def charge_setup_confirmed_purchases!(purchases)
      reference_purchase = purchases.first
      reference_purchase.with_lock do
        # with_lock reloads only the reference: when a concurrent confirm charged or finalized
        # this group while we waited, the sibling rows changed too, and the perform loop would
        # otherwise feed stale in_progress copies to Purchase::ConfirmService, whose setup-only
        # guard fails purchases whose money already moved.
        (purchases - [reference_purchase]).each(&:reload)
        next unless reference_purchase.in_progress?

        if reference_purchase.processor_payment_intent.present?
          # A concurrently retried confirm charged this group while we waited for the lock.
          finalize_setup_charged_purchases!(purchases)
        else
          charge_setup_confirmed_purchases_locked!(purchases)
        end
      end
    end

    def finalize_setup_charged_purchases!(purchases)
      reference_purchase = purchases.first
      charge_intent = ChargeProcessor.get_charge_intent(
        reference_purchase.merchant_account,
        reference_purchase.processor_payment_intent.intent_id
      )
      finalize_charged_purchases(purchases, charge_intent)
    end

    def finalize_charged_purchases(purchases, charge_intent)
      purchases.each do |purchase|
        setup_charge_results[purchase.id] = Purchase::FinalizeConfirmedChargeService.new(purchase:, charge_intent:).perform
      end
    end

    def charge_setup_confirmed_purchases_locked!(purchases)
      reference_purchase = purchases.first
      merchant_account = reference_purchase.merchant_account
      credit_card = reference_purchase.credit_card
      setup_intent_id = reference_purchase.processor_setup_intent_id
      setup_intent = credit_card.present? ? ChargeProcessor.get_setup_intent(merchant_account, setup_intent_id) : nil

      unless setup_intent&.succeeded?
        if setup_intent&.requires_action?
          # SI on another Stripe account — the buyer hasn't confirmed it yet. Leave these
          # purchases in_progress and tell the frontend to confirmCardSetup on this account.
          connect_acct = merchant_account&.is_a_stripe_connect_account? ? merchant_account.charge_processor_merchant_id : nil
          response = {
            success: true,
            requires_card_setup: true,
            client_secret: setup_intent.client_secret,
            intent_id: setup_intent_id,
            intent_type: "setup",
            order: {
              id: order.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now),
              stripe_connect_account_id: connect_acct
            }
          }
          purchases.each { |p| setup_charge_results[p.id] = { awaiting_setup: response } }
          return
        end

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
      if merchant_account.is_a_stripe_connect_account? && setup_intent.payment_method_id.present?
        # Stripe binds the confirmed e-mandate to the exact payment method the SetupIntent was
        # confirmed with — the clone already on the connected account. prepare! would clone a
        # fresh copy, which Stripe treats as a different, mandate-less method off-session.
        chargeable.use_connected_account_payment_method!(setup_intent.payment_method_id)
      else
        chargeable.prepare!
      end

      create_service = Charge::CreateService.new(
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
        # The SetupIntent pause happened before the group's original charge, so presentment
        # never ran; the resume charge must lock the same buyer-currency quote the checkout
        # displayed (Charge::CreateService fails closed if it expired).
        params: { buyer_currency_quote: params[:buyer_currency_quote].presence },
      )
      charge = create_service.perform

      charge_intent = charge.charge_intent
      if charge_intent.blank?
        # A connection loss after Stripe may have accepted the debit must stay pending: failing
        # these purchases and telling the buyer the card was not charged would let them pay twice.
        if create_service.processor_outcome_unknown
          purchases.each do |purchase|
            purchase.errors.clear
            purchase.error_code = nil
            purchase.stripe_error_code = nil
          end
          # client_confirmed routes payment_intent.succeeded / payment_failed webhooks into the
          # async finalize rails if the lost response actually created a debit.
          charge.update!(client_confirmed: true)
        end
        # Definitive nil-intent failures already carry buyer-facing errors for per-purchase confirms.
        return
      end

      if credit_card.requires_mandate?
        existing = credit_card.json_data.to_h
        credit_card.update!(json_data: { "stripe_setup_intent_ids" => existing["stripe_setup_intent_ids"], "stripe_payment_intent_id" => charge_intent.id }.compact)
      end
      return unless charge_intent.is_a?(StripeChargeIntent)

      # The debit can outlive this request (India intents stay `processing` for up to 26h),
      # and the buyer may never come back to retry the confirm. client_confirmed is what
      # routes the intent's payment_intent.succeeded / payment_failed webhooks into the
      # async finalize/fail rails (Purchase::ChargeEventsHandler); without it these
      # purchases would sit in_progress forever.
      charge.update!(client_confirmed: true)

      purchases.each do |purchase|
        purchase.create_processor_payment_intent!(intent_id: charge_intent.id)
      end
      # Finalize from the intent we just created instead of leaving these purchases to
      # Purchase::ConfirmService: its confirm_charge_intent! re-confirms any non-succeeded
      # intent, and Stripe rejects that for a `processing` one (India debits stay processing
      # for up to 26h with the debit already scheduled).
      finalize_charged_purchases(purchases, charge_intent)
    end
end
