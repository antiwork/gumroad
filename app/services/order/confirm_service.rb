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
            # Match FinalizeConfirmedChargeService: India debits stay processing for hours.
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

    # India multi-seller carts pause at a SetupIntent with no PaymentIntent; after confirm,
    # create each group's off-session charge or fulfillment marks success with no money moved.
    def charge_seller_groups_awaiting_setup_confirmation!
      browser_stripe_error = CardParamsHelper.check_for_errors(params).present?

      order.purchases.group_by { |purchase| purchase.charge&.id }.each_value do |seller_purchases|
        # Even with a browser-reported stripe_error, already-submitted debits must still be
        # reconciled — failing them would leave money moving without fulfillment.
        if browser_stripe_error
          charged = seller_purchases.select { |purchase| charged_after_setup_awaiting_finalization?(purchase) }
          uncertain = seller_purchases.select do |purchase|
            purchase.in_progress? && purchase.charge&.client_confirmed? && purchase.processor_payment_intent.blank?
          end
          finalize_setup_charged_purchases!(charged) if charged.any?
          uncertain.each { |purchase| setup_charge_results[purchase.id] = :pending }
          next
        end
        pending = seller_purchases.select { |purchase| awaiting_charge_after_setup?(purchase) }
        charged = seller_purchases.select { |purchase| charged_after_setup_awaiting_finalization?(purchase) }
        next if pending.none? && charged.none?

        begin
          if pending.any?
            charge_setup_confirmed_purchases!(pending)
          else
            # Retried confirm: group's charge exists and India stays `processing` (~26h).
            # ConfirmService would re-confirm, which Stripe rejects — finalize from retrieve only.
            finalize_setup_charged_purchases!(charged)
          end
        rescue => e
          Rails.logger.error("Error charging confirmed setup intent for order #{order.id}: #{e.class} => #{e.message}")
          ErrorNotifier.notify(e, order_id: order.id)
          (pending + charged).each do |purchase|
            if purchase.processor_payment_intent.present? || purchase.charge&.client_confirmed?
              # The charge exists, or a prior uncertain attempt already submitted a debit
              # (client_confirmed without a stored PI). Failing the purchase could lose a
              # payment that is still going to capture. Report processing and let webhooks finish it.
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

    # Group already has an off-session charge (this path, or ChargeService with no mandate
    # pause — stripe_status `processing`, no SetupIntent) and is still in_progress. Finalize
    # from retrieve only: Stripe rejects confirming a processing intent already scheduled.
    def charged_after_setup_awaiting_finalization?(purchase)
      purchase.in_progress? &&
        purchase.errors.empty? &&
        (purchase.processor_setup_intent_id.present? || purchase.stripe_status == StripeIntentStatus::PROCESSING) &&
        (purchase.processor_payment_intent.present? || purchase.stripe_transaction_id.present?) &&
        !purchase.free_purchase? &&
        !purchase.is_test_purchase? &&
        !purchase.is_free_trial_purchase? &&
        !purchase.is_preorder_authorization?
    end

    def charge_setup_confirmed_purchases!(purchases)
      reference_purchase = purchases.first
      reference_purchase.with_lock do
        # with_lock reloads only the reference; siblings may have charged/finalized while we
        # waited. Without reloading them, ConfirmService's setup-only guard fails paid rows.
        (purchases - [reference_purchase]).each(&:reload)
        reference_purchase.charge&.reload
        next unless reference_purchase.in_progress?

        if reference_purchase.processor_payment_intent.present?
          # A concurrently retried confirm charged this group while we waited for the lock.
          finalize_setup_charged_purchases!(purchases)
        else
          # Includes uncertain client_confirmed retries: CreateService uses setup_confirmed_resume
          # idempotency so Stripe returns the first PaymentIntent instead of minting a second.
          charge_setup_confirmed_purchases_locked!(purchases)
        end
      end
    end

    # Guest one-time India mandates pause without creating a CreditCard. Rebuild a Chargeable
    # from the SetupIntent's payment method so the resume charge can still run. Prefer
    # StripeChargeableCreditCard so Connect trusted-prepare can bind the SI's PM without cloning.
    def chargeable_for_setup_confirmed_resume(reference_purchase, credit_card, merchant_account, setup_intent)
      return credit_card.to_chargeable(merchant_account:) if credit_card.present?

      payment_method_id = setup_intent.payment_method_id
      raise "Confirmed SetupIntent is missing a payment method" if payment_method_id.blank?

      stripe_account = if merchant_account&.is_a_stripe_connect_account?
        { stripe_account: merchant_account.charge_processor_merchant_id }
      else
        {}
      end
      payment_method = Stripe::PaymentMethod.retrieve(payment_method_id, stripe_account)
      card = payment_method.try(:card)
      customer_id = setup_intent.try(:customer_id).presence || payment_method.try(:customer)
      customer_id = customer_id.id if customer_id.respond_to?(:id)
      last4 = card.try(:last4)
      card_type = StripeCardType.to_new_card_type(card.try(:brand)) if card.try(:brand).present?
      number_length = ChargeableVisual.get_card_length_from_card_type(card_type) if card_type.present?
      visual = ChargeableVisual.build_visual(last4, number_length) if last4.present? && number_length.present?

      stripe_chargeable = StripeChargeableCreditCard.new(
        merchant_account,
        customer_id,
        payment_method_id,
        card.try(:fingerprint),
        setup_intent.id,
        nil,
        last4,
        number_length,
        visual,
        card.try(:exp_month),
        card.try(:exp_year),
        card_type,
        card.try(:country),
        reference_purchase.zip_code
      )
      Chargeable.new([stripe_chargeable])
    end

    def finalize_setup_charged_purchases!(purchases)
      reference_purchase = purchases.first
      intent_id = reference_purchase.processor_payment_intent&.intent_id
      # stripe_transaction_id alone (no stored PI) means money may already have moved;
      # cannot retrieve. Leave pending for webhooks/reconcile rather than NoMethodError.
      if intent_id.blank?
        purchases.each { |purchase| setup_charge_results[purchase.id] = :pending }
        return
      end
      charge_intent = ChargeProcessor.get_charge_intent(
        reference_purchase.merchant_account,
        intent_id
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
      # Guest / save_card=false India pauses still store processor_setup_intent_id on the
      # purchase without a CreditCard row. Resume from that verified SetupIntent instead of
      # requiring a saved-card record.
      setup_intent = setup_intent_id.present? ? ChargeProcessor.get_setup_intent(merchant_account, setup_intent_id) : nil

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
          purchases.each do |purchase|
            setup_charge_results[purchase.id] = {
              awaiting_setup: response.merge(permalink: purchase.link.unique_permalink)
            }
          end
          return
        end

        purchases.each do |purchase|
          purchase.error_code = PurchaseErrorCode::INDIA_CARD_MANDATE_MISSING
          purchase.errors.add(:base, "We couldn't authorize your card for this payment. Please try again or use a different payment method.")
        end
        return
      end

      existing_charge = reference_purchase.charge
      if existing_charge&.client_confirmed?
        # A prior uncertain resume already submitted (or may have submitted) a debit. Replaying
        # CreateService can reject an expired quote and clear presentment snapshots needed to
        # book a delayed success — reconcile the existing charge instead.
        purchases.each do |purchase|
          purchase.errors.clear
          purchase.error_code = nil
          purchase.stripe_error_code = nil
          purchase.update!(stripe_status: StripeIntentStatus::PROCESSING) if purchase.stripe_status.blank?
          setup_charge_results[purchase.id] = :pending
        end
        ReconcileClientConfirmedChargeJob.perform_in(30.seconds, existing_charge.id)
        return
      end

      chargeable = chargeable_for_setup_confirmed_resume(reference_purchase, credit_card, merchant_account, setup_intent)
      # Card json_data can hold another group's intent; bind this group's confirmed SetupIntent.
      # Trusted prepare on Connect attaches that SI's PM to a connected Customer for renewals.
      chargeable.stripe_setup_intent_id = setup_intent_id if chargeable.respond_to?(:stripe_setup_intent_id=)
      if chargeable.respond_to?(:prepare_with_trusted_setup_intent!)
        chargeable.prepare_with_trusted_setup_intent!
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
        params: {
          buyer_currency_quote: params[:buyer_currency_quote].presence,
          setup_confirmed_resume: true
        },
      )
      begin
        charge = create_service.perform
      rescue => e
        # Stripe may have accepted the debit before a later error (e.g. rate limit loading the
        # Charge). Only mark uncertain after CreateService was entered.
        Rails.logger.error("Error in setup-confirmed Charge::CreateService for order #{order.id}: #{e.class} => #{e.message}")
        ErrorNotifier.notify(e, order_id: order.id)
        reference_charge = reference_purchase.charge
        if reference_charge.present?
          purchases.each do |purchase|
            purchase.errors.clear
            purchase.error_code = nil
            purchase.stripe_error_code = nil
            purchase.update!(stripe_status: StripeIntentStatus::PROCESSING) if purchase.stripe_status.blank?
            setup_charge_results[purchase.id] = :pending
          end
          reference_charge.update!(client_confirmed: true)
          ReconcileClientConfirmedChargeJob.perform_in(30.seconds, reference_charge.id)
          return
        end
        raise
      end

      charge_intent = charge.charge_intent
      if charge_intent.blank?
        # Stay pending if Stripe may have accepted the debit (connection loss) or a prior
        # uncertain attempt set client_confirmed and this retry cannot create — avoid double pay.
        if create_service.processor_outcome_unknown || charge.client_confirmed?
          purchases.each do |purchase|
            purchase.errors.clear
            purchase.error_code = nil
            purchase.stripe_error_code = nil
            # payment_settling requires a non-null stripe_status; without it another cart can
            # double-charge once the short duplicate window expires while reconciliation lags.
            purchase.update!(stripe_status: StripeIntentStatus::PROCESSING) if purchase.stripe_status.blank?
            setup_charge_results[purchase.id] = :pending
          end
          charge.update!(client_confirmed: true)
          ReconcileClientConfirmedChargeJob.perform_in(30.seconds, charge.id)
        end
        # Definitive nil-intent failures already carry buyer-facing errors for per-purchase confirms.
        return
      end

      begin
        if credit_card&.requires_mandate?
          account_key = merchant_account.is_a_stripe_connect_account? ? merchant_account.charge_processor_merchant_id : "platform"
          credit_card.with_lock do
            credit_card.reload
            existing = credit_card.json_data.to_h
            ids = existing["stripe_setup_intent_ids"].is_a?(Hash) ? existing["stripe_setup_intent_ids"].dup : {}
            # Persist the confirmed SetupIntent for this account (replacing an insufficient prior
            # mandate) and migrate any legacy scalar so renewals resolve Connect PM binding.
            ids[account_key] = setup_intent_id.presence || ids[account_key].presence || existing["stripe_setup_intent_id"]
            ids.compact!
            next_data = existing.merge("stripe_payment_intent_id" => charge_intent.id)
            next_data["stripe_setup_intent_ids"] = ids if ids.present?
            credit_card.update!(json_data: next_data.compact)
          end
        end

        return unless charge_intent.is_a?(StripeChargeIntent)

        # Debit can outlive this request (India `processing` up to 26h). client_confirmed
        # routes payment_intent webhooks into ChargeEventsHandler; without it, sits forever.
        charge.update!(client_confirmed: true)

        purchases.each do |purchase|
          purchase.create_processor_payment_intent!(intent_id: charge_intent.id)
        end
        # Finalize here: ConfirmService#confirm_charge_intent! re-confirms non-succeeded
        # intents, which Stripe rejects while India stays `processing` with debit scheduled.
        finalize_charged_purchases(purchases, charge_intent)
      rescue => e
        # Local persistence failed after Stripe already accepted the debit. Persist recovery
        # markers outside the rolled-back work so webhooks/reconcile can finish fulfillment.
        Rails.logger.error("Error persisting setup-confirmed charge for order #{order.id}: #{e.class} => #{e.message}")
        ErrorNotifier.notify(e, order_id: order.id, charge_id: charge.id)
        charge.reload
        charge.update!(client_confirmed: true, stripe_payment_intent_id: charge.stripe_payment_intent_id.presence || charge_intent.id)
        purchases.each do |purchase|
          purchase.reload
          purchase.update!(stripe_status: StripeIntentStatus::PROCESSING) if purchase.stripe_status.blank?
          purchase.create_processor_payment_intent!(intent_id: charge_intent.id) if purchase.processor_payment_intent.blank?
          setup_charge_results[purchase.id] = :pending
        end
        ReconcileClientConfirmedChargeJob.perform_in(30.seconds, charge.id)
      end
    end
end
