# frozen_string_literal: true

class Order::ChargeService
  include Events, Order::ResponseHelpers
  include CurrencyHelper

  attr_accessor :order, :params, :charge_intent, :setup_intent, :charge_responses

  def initialize(order:, params:)
    @order = order
    @params = params
    @charge_responses = {}
  end

  def perform
    # We need to make off session charges if there are products from more than one seller
    # In such case we create a reusable payment method before initiating the order from front-end
    off_session = order.purchases.non_free.pluck(:seller_id).uniq.count > 1

    # All remaining purchases need to be charged that are still in progress
    # Create a combined charge for all purchases belonging to the same seller
    # i.e. one charge per seller
    # Exclude purchases that already have a payment intent (e.g. subscription restarts
    # requiring SCA — they are confirmed later via Order::ConfirmService)
    chargeable_purchases = order.purchases.reject { _1.processor_payment_intent.present? }
    rejected_by_offer_code_limit = Purchase.validate_offer_code_usage_across_line_items(chargeable_purchases)
    purchases_by_seller = chargeable_purchases.group_by(&:seller_id)

    purchases_by_seller.each do |seller_id, seller_purchases|
      self.charge_intent = nil
      self.setup_intent = nil

      # Every purchase in this seller group has already reached a terminal state
      # (e.g. rejected by `validate_offer_code_usage_across_line_items`) — skip
      # creating a Charge record that would have no Stripe activity attached.
      next if seller_purchases.none?(&:in_progress?)

      charge = order.charges.create!(seller_id:)
      seller_purchases.each do |purchase|
        next unless purchase.in_progress? && purchase.errors.empty?
        purchase.charge = charge
        purchase.save!
        # Mark free or test purchase as successful as it does not require any further processing
        mark_successful_if_free_or_test_purchase(purchase)
      end

      non_free_seller_purchases = seller_purchases.select(&:in_progress?)
      next unless non_free_seller_purchases.present?

      # All purchases belonging to the same seller should have the same destination merchant account
      if non_free_seller_purchases.pluck(:merchant_account_id).uniq.compact.count > 1
        raise StandardError, "Error charging order #{order.id}:: Different merchant accounts in purchases: #{non_free_seller_purchases.pluck(:id)}"
      end

      params_for_chargeable = params.merge(product_permalink: non_free_seller_purchases.first.link.unique_permalink)
      card_data_handling_mode, card_data_handling_error, chargeable_from_params = create_chargeable_from_params(params_for_chargeable)

      setup_future_charges = non_free_seller_purchases.any? do |purchase|
        (purchase.purchaser.present? && purchase.save_card && chargeable_from_params&.can_be_saved?) ||
          purchase.is_preorder_authorization? || purchase.link.is_recurring_billing?
      end

      if setup_future_charges && chargeable_from_params.present?
        credit_card = CreditCard.create(chargeable_from_params, card_data_handling_mode, order.purchaser)
        credit_card.users << order.purchaser if order.purchaser.present?
      end

      chargeable = prepare_purchases_for_charge(non_free_seller_purchases,
                                                card_data_handling_mode, card_data_handling_error,
                                                chargeable_from_params, credit_card)

      # If all purchases are either free-trial or preorder authorizations
      # then we don't need to create a charge
      # but only setup a reusable payment method for the future charges.
      # Braintree and PayPal payment methods are already setup for future charges,
      # in case of Stripe, create a setup intent.
      all_in_progress_purchases = non_free_seller_purchases.reject { !_1.in_progress? || !_1.errors.empty? }
      only_setup_for_future_charges = all_in_progress_purchases.present? && all_in_progress_purchases.all? do |purchase|
        purchase.is_free_trial_purchase? || purchase.is_preorder_authorization?
      end

      if only_setup_for_future_charges
        setup_for_future_charges_without_charging(non_free_seller_purchases, chargeable, chargeable_from_params.blank? && chargeable.present?)
      else
        create_charge_for_seller_purchases(non_free_seller_purchases, chargeable, off_session, setup_future_charges)
      end
    rescue => e
      # Per seller group: earlier groups' charges are already captured and the loop carries
      # on, so this is the partial-order path, not an aborted checkout.
      Rails.logger.error("Error charging order (#{order.id}):: #{e.class} => #{e.message} => #{e.backtrace}")
      begin
        ErrorNotifier.notify(e, order_id: order.id, seller_id:)
      rescue => notify_error
        # A raising notifier must not stop the remaining seller groups from being charged.
        Rails.logger.error("Error reporting charge failure for order (#{order.id}):: #{notify_error.class} => #{notify_error.message}")
      end
    ensure
      # Ensure all purchases of the charge are transitioned to a terminal state
      # and each line item has a response. Include purchases rejected by
      # `Purchase.validate_offer_code_usage_across_line_items` so their line items
      # get an error response in `charge_responses`.
      ensure_all_purchases_processed((non_free_seller_purchases || seller_purchases.select(&:in_progress?)) + (seller_purchases & rejected_by_offer_code_limit))
    end

    charge_responses
  end

  def mark_successful_if_free_or_test_purchase(purchase)
    if purchase.in_progress? && (purchase.free_purchase? || (purchase.is_test_purchase? && !purchase.is_preorder_authorization?))
      Purchase::MarkSuccessfulService.new(purchase).perform
      handle_recommended_purchase(purchase)
      line_item_uid = params[:line_items].select { |line_item| line_item[:permalink] == purchase.link.unique_permalink }[0][:uid]
      charge_responses[line_item_uid] = purchase.purchase_response
    end
  end

  def create_chargeable_from_params(params)
    card_data_handling_mode = CardParamsHelper.get_card_data_handling_mode(params)
    card_data_handling_error = CardParamsHelper.check_for_errors(params)

    chargeable = CardParamsHelper.build_chargeable(params, params[:browser_guid])
    chargeable&.prepare!

    return card_data_handling_mode, card_data_handling_error, chargeable
  end

  def prepare_purchases_for_charge(purchases, card_data_handling_mode, card_data_handling_error, chargeable, credit_card)
    purchases.each do |purchase|
      purchase.card_data_handling_mode = card_data_handling_mode
      purchase.card_data_handling_error = card_data_handling_error
      purchase.chargeable = chargeable
      purchase.charge_processor_id ||= chargeable&.charge_processor_id

      chargeable = purchase.load_and_prepare_chargeable(credit_card) unless purchase.is_test_purchase?
      if Feature.active?(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, purchase.seller) &&
         !StripeIntentChargeRouting.direct_charge_account?(purchase.merchant_account)
        purchase.chargeable = chargeable
      end

      purchase.check_for_blocked_customer_emails
      purchase.validate_purchasing_power_parity
    end

    chargeable
  end

  def setup_for_future_charges_without_charging(purchases, chargeable, card_already_saved)
    merchant_account = purchases.first.merchant_account
    locked_quote = locked_setup_buyer_currency_quote(purchases:, merchant_account:, chargeable:)
    return if locked_quote == false

    saved_card_needs_indian_mandate = card_already_saved && chargeable&.requires_mandate? &&
      purchases.any?(&:india_card_mandate_reliability_enabled?)
    if merchant_account.stripe_charge_processor? && (!card_already_saved || saved_card_needs_indian_mandate)
      mandate_options = mandate_options_for_stripe(purchases:, with_currency: true)
      mandate_options = mandate_options_in_setup_currency(mandate_options, locked_quote)
      self.setup_intent = ChargeProcessor.setup_future_charges!(merchant_account, chargeable, mandate_options:)

      if setup_intent.present?
        purchases.each do |purchase|
          purchase.mark_indian_card_mandate_registration! if mandate_options.present? && purchase.credit_card&.requires_mandate?
          purchase.update!(processor_setup_intent_id: setup_intent.id)
          purchase.charge.update!(stripe_setup_intent_id: setup_intent.id)
          if !card_already_saved && purchase.credit_card&.requires_mandate?
            purchase.credit_card.update!(json_data: { stripe_setup_intent_id: setup_intent.id })
          end

          if setup_intent.succeeded?
            fix_setup_later_charge_presentment(purchase, locked_quote)
            # Indian cards register an RBI e-mandate on this setup intent; renewals reference it.
            # If Stripe completed the setup without creating a Mandate object, every future
            # off-session renewal will be declined by the issuer — report it now rather than
            # letting it surface as an unexplainable decline at first renewal.
            begin
              if purchase.credit_card&.requires_mandate? && setup_intent.mandate.blank?
                ErrorNotifier.notify(
                  "Indian card recurring purchase completed without a registered e-mandate — its renewals will be declined by the issuer",
                  purchase: purchase.external_id,
                  stripe_setup_intent: setup_intent.id
                )
              end
            rescue => e
              # This check is observability only; never let it break charge processing.
              ErrorNotifier.notify(e, purchase: purchase.external_id)
            end
            mark_setup_future_charges_successful(purchase)
          elsif setup_intent.requires_action?
            fix_setup_later_charge_presentment(purchase, locked_quote)
            # Check back later to see if the purchase has been completed. If not, transition to a failed state.
            FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
          else
            purchase.errors.add :base, "Sorry, something went wrong." if purchase.errors.empty?
          end
        end
      end
    else
      purchases.each do |purchase|
        fix_setup_later_charge_presentment(purchase, locked_quote)
        mark_setup_future_charges_successful(purchase)
      end
    end
  end

  def locked_setup_buyer_currency_quote(purchases:, merchant_account:, chargeable:)
    quote_token = params[:buyer_currency_quote].presence if merchant_account&.stripe_charge_processor?
    return if quote_token.blank?

    seller = purchases.first.seller
    decision = Checkout::BuyerCurrencyEligibility.new(
      order:,
      seller:,
      merchant_account:,
      chargeable:,
      purchases:,
      params:,
      setup_future_charges: true,
      off_session: false
    ).decision
    raise Checkout::BuyerCurrencyQuote::InvalidToken, "charge-time eligibility fallback (#{decision.fallback_reason})" unless decision.eligible?

    Checkout::BuyerCurrencyQuote.verify!(
      token: quote_token,
      seller:,
      merchant_account:,
      currency: decision.currency,
      canonical_total_cents: 0,
      canonical_line_items: [],
      later_charge_canonical_line_items: Purchase::FixLaterChargePresentmentService.canonical_line_items_for(purchases)
    )
  rescue Checkout::BuyerCurrencyQuote::InvalidToken => e
    Rails.logger.info("Buyer currency setup quote rejected for order #{order.id}: #{e.message}")
    purchases.each do |purchase|
      purchase.errors.add(:base, Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE)
      purchase.error_code = PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID
    end
    false
  end

  def fix_setup_later_charge_presentment(purchase, locked_quote)
    return if locked_quote.blank?

    Purchase::FixLaterChargePresentmentService.new(purchase:, locked_quote:).perform
  end

  def mandate_options_in_setup_currency(mandate_options, locked_quote)
    return mandate_options if mandate_options.blank? || locked_quote.blank?
    return mandate_options unless StripeChargeProcessor.indian_card_mandate_currency_supported?(locked_quote.currency)

    canonical_cap_cents = mandate_options.dig(:payment_method_options, :card, :mandate_options, :amount)
    return mandate_options if canonical_cap_cents.blank? || !locked_quote.fx_rate&.positive?

    presentment_cap_cents = (
      BigDecimal(canonical_cap_cents.to_s) / subunit_to_unit(Currency::USD) /
        locked_quote.fx_rate * subunit_to_unit(locked_quote.currency)
    ).ceil
    inner = mandate_options[:payment_method_options][:card][:mandate_options]
              .merge(amount: presentment_cap_cents, currency: locked_quote.currency)
    mandate_options.deep_merge(payment_method_options: { card: { mandate_options: inner } })
  end

  def mark_setup_future_charges_successful(purchase)
    return unless purchase.in_progress?

    if purchase.is_free_trial_purchase?
      Purchase::MarkSuccessfulService.new(purchase).perform
      handle_recommended_purchase(purchase)
    else
      preorder = purchase.preorder
      preorder.authorize!
      error_message = preorder.errors.full_messages[0]
      if purchase.is_test_purchase?
        preorder.mark_test_authorization_successful!
      elsif error_message.present?
        Purchase::MarkFailedService.new(purchase).perform
      else
        preorder.mark_authorization_successful!
      end
    end

    purchase.charge.update!(credit_card_id: purchase.credit_card.id)
  end

  def create_charge_for_seller_purchases(purchases, chargeable, off_session, setup_future_charges)
    purchases_to_charge = purchases.reject do |purchase|
      purchase.is_free_trial_purchase? || purchase.is_preorder_authorization? || purchase.is_test_purchase? ||
        !purchase.errors.empty? || !purchase.in_progress?
    end
    mandate_purchases = purchases.select do |purchase|
      purchase.in_progress? && purchase.errors.empty? &&
        (purchase.is_original_subscription_purchase? || purchase.is_preorder_authorization? || purchase.is_upgrade_purchase? || purchase.setup_future_charges)
    end

    if purchases_to_charge.present?
      amount_cents = purchases_to_charge.sum(&:total_transaction_cents)
      gumroad_amount_cents = purchases_to_charge.sum(&:total_transaction_amount_for_gumroad_cents)
      merchant_account = purchases.first.merchant_account
      seller = User.find(purchases.first.seller_id)
      statement_description = seller.name_or_username
      mandate_options = mandate_options_for_stripe(purchases: mandate_purchases) if mandate_purchases.present?
      if setup_future_charges && mandate_options.present? && chargeable&.requires_mandate?
        mandate_purchases.each(&:mark_indian_card_mandate_registration!)
      end

      charge = Charge::CreateService.new(
        order:,
        seller:,
        merchant_account:,
        chargeable:,
        purchases: purchases_to_charge,
        amount_cents:,
        gumroad_amount_cents:,
        setup_future_charges:,
        off_session:,
        statement_description:,
        mandate_options: setup_future_charges ? mandate_options : nil,
        params:,
      ).perform

      self.charge_intent = charge.charge_intent
      # charge_intent is nil when the processor call was rescued (e.g. a quote/settlement
      # mismatch) — Charge::CreateService returns the charge with no intent attached in that case.
      if charge_intent.present? && charge.credit_card&.requires_mandate?
        card_json_data = mandate_options.present? ? {} : charge.credit_card.json_data.to_h
        charge.credit_card.update!(
          json_data: card_json_data.merge("stripe_payment_intent_id" => charge_intent.id)
        )
      end

      if charge_intent&.succeeded?
        charge_waiting_for_flow_of_funds = charge_intent_waiting_for_flow_of_funds?(charge)
        FinalizeBuyerPresentmentChargeJob.perform_in(FinalizeBuyerPresentmentChargeJob::INITIAL_DELAY, charge.id) if charge_waiting_for_flow_of_funds

        purchases.each do |purchase|
          if purchases_to_charge.include?(purchase)
            purchase.paypal_order_id = charge.paypal_order_id if charge.paypal_order_id.present?
            if charge_intent.is_a? StripeChargeIntent
              save_processor_payment_intent!(purchase, charge_intent.id)
            end
            purchase.save_charge_data(charge_intent.charge,
                                      chargeable:,
                                      allow_missing_flow_of_funds: charge_waiting_for_flow_of_funds)
          end

          next unless purchase.in_progress? && purchase.errors.empty?
          next if charge_waiting_for_flow_of_funds && purchase_has_charge_data?(purchase)
          Purchase::MarkSuccessfulService.new(purchase).perform
          handle_recommended_purchase(purchase)
        end
      elsif charge_intent&.requires_action?
        purchases_to_charge.each do |purchase|
          save_processor_payment_intent!(purchase, charge_intent.id)
        end
      else
        purchases.each do |purchase|
          next unless purchase.in_progress? && purchase.errors.empty?
          purchase.errors.add :base, "Sorry, something went wrong."
        end
      end
    end
  end

  def ensure_all_purchases_processed(purchases)
    return if purchases.nil?

    purchases.each do |purchase|
      line_item_uid = params[:line_items].find do |line_item|
        purchase.link.unique_permalink == line_item[:permalink] &&
          (line_item[:variants].blank? || purchase.variant_attributes.first&.external_id == line_item[:variants]&.first)
      end[:uid]

      next if charge_responses[line_item_uid].present?

      if purchase.errors.present? || purchase.failed?
        charge_responses[line_item_uid] = error_response(purchase.errors.first&.message || "Sorry, something went wrong. Please try again.", purchase:)
      end

      # Mark purchases that are still stuck in progress as failed
      # unless there's an SCA verification pending in which case all purchases
      # are expected to be in progress, and we schedule a job to check them back later.
      if purchase.in_progress?
        if purchase.free_purchase? || (purchase.is_test_purchase? && !purchase.is_preorder_authorization?)
          Purchase::MarkSuccessfulService.new(purchase).perform
          handle_recommended_purchase(purchase)
        elsif charge_intent&.requires_action? || setup_intent&.requires_action?
          # Check back later to see if the purchase has been completed. If not, transition to a failed state.
          FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
        elsif purchase_waiting_for_flow_of_funds?(purchase) && purchase_has_charge_data?(purchase)
          Rails.logger.info("Leaving purchase #{purchase.id} in_progress because charge #{charge_intent.charge.id} is missing flow of funds")
        elsif charge_intent&.succeeded? && purchase_has_charge_data?(purchase)
          mark_charged_purchase_successful(purchase)
        else
          Purchase::MarkFailedService.new(purchase).perform
        end
      end

      if purchase.errors.present? || purchase.failed?
        charge_responses[line_item_uid] ||= error_response(purchase.errors.first&.message || "Sorry, something went wrong. Please try again.", purchase:)
      elsif charge_intent&.requires_action?
        charge_responses[line_item_uid] ||= {
          success: true,
          requires_card_action: true,
          client_secret: charge_intent.client_secret,
          order: {
            id: order.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now),
            stripe_connect_account_id: order.charges.last.merchant_account.is_a_stripe_connect_account? ? order.charges.last.merchant_account.charge_processor_merchant_id : nil
          }
        }
      elsif setup_intent&.requires_action?
        charge_responses[line_item_uid] ||= {
          success: true,
          requires_card_setup: true,
          client_secret: setup_intent.client_secret,
          order: {
            id: order.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now),
            stripe_connect_account_id: order.purchases.last.merchant_account.is_a_stripe_connect_account? ? order.purchases.last.merchant_account.charge_processor_merchant_id : nil
          }
        }
      elsif purchase_waiting_for_flow_of_funds?(purchase) && purchase_has_charge_data?(purchase)
        charge_responses[line_item_uid] ||= purchase_pending_processor_settlement_response(purchase)
      else
        charge_responses[line_item_uid] ||= purchase.purchase_response
        handle_recommended_purchase(purchase)
      end
    end
  end

  def purchase_has_charge_data?(purchase)
    purchase.errors.empty? && (purchase.stripe_transaction_id.present? || purchase.paypal_order_id.present?)
  end

  def save_processor_payment_intent!(purchase, intent_id)
    if purchase.processor_payment_intent.present?
      purchase.processor_payment_intent.update!(intent_id:)
    else
      purchase.create_processor_payment_intent!(intent_id:)
    end
  end

  def purchase_waiting_for_flow_of_funds?(purchase)
    charge_intent_waiting_for_flow_of_funds?(purchase.charge)
  end

  def charge_intent_waiting_for_flow_of_funds?(charge)
    charge_intent&.succeeded? &&
      charge_intent.is_a?(StripeChargeIntent) &&
      (charge&.charge_presentment.present? || charge&.merchant_account&.user_id.present?) &&
      charge_intent.charge.flow_of_funds.blank?
  end

  def mark_charged_purchase_successful(purchase)
    apply_seller_balance_transaction(purchase)

    Purchase::MarkSuccessfulService.new(purchase).perform
  rescue StandardError => e
    Rails.logger.error("Error finalizing charged purchase (#{purchase.id}):: #{e.class} => #{e.message} => #{e.backtrace}")
    purchase.errors.add(:base, "Sorry, something went wrong. Please try again.") unless purchase.successful?
  end

  def handle_recommended_purchase(purchase)
    return unless purchase.was_product_recommended

    purchase.handle_recommended_purchase
  rescue StandardError => e
    Rails.logger.error("Error handling recommended purchase (#{purchase.id}):: #{e.class} => #{e.message} => #{e.backtrace}")
  end

  def apply_seller_balance_transaction(purchase)
    return unless purchase.charged_using_gumroad_merchant_account?
    return if purchase.purchase_success_balance_id.present?

    seller_balance_transaction = purchase.balance_transactions.where(user: purchase.seller).where.not(balance_id: nil).last ||
                                 purchase.balance_transactions.where(user: purchase.seller, balance_id: nil).last
    return unless seller_balance_transaction

    seller_balance_transaction.update_balance! if seller_balance_transaction.balance_id.blank?
    purchase.update!(purchase_success_balance: seller_balance_transaction.balance)
  end

  # The India e-mandate registered with this charge caps every future off-session charge made
  # against the saved card (RBI rules; see Purchase#mandate_options_for_stripe). The cap is a
  # PER-CHARGE ceiling, not a total budget: Stripe authorizes each off-session charge whose
  # amount is at or under `amount`, and anything above it needs the buyer to authenticate again.
  #
  # Renewals are charged one subscription at a time — `Subscription#schedule_charge` enqueues
  # RecurringChargeWorker per subscription id, and each run charges exactly one purchase — so
  # even when one cart creates several subscriptions sharing this mandate, no single future
  # charge is ever the cart's combined total. The cap therefore has to cover the LARGEST
  # individual renewal, and sizing it to the sum of the cart would authorize any one renewal to
  # silently grow to the whole cart's worth before re-authentication kicks in.
  #
  # What each purchase contributes is its own `mandate_maximum_amount_cents` rather than the
  # amount charged today, which is the part a multi-item cart was missing: when a subscription
  # is bought with a limited-duration discount, its renewals bill the undiscounted price once
  # the discount's billing cycles run out. Taking the max over charged totals (what this used
  # to do) sizes the cap below that later, higher renewal and the buyer gets an unrecoverable
  # decline. Single-purchase carts already get this headroom from
  # Purchase#mandate_options_for_stripe; this gives multi-item carts the same treatment.
  def mandate_options_for_stripe(purchases:, with_currency: false)
    if purchases.one? && !purchases.first.is_multi_buy?
      return purchases.first.mandate_options_for_stripe(with_currency:)
    end

    mandate_amount = purchases.map(&:mandate_maximum_amount_cents).max

    mandate_options = {
      payment_method_options: {
        card: {
          mandate_options: {
            reference: StripeChargeProcessor::MANDATE_PREFIX + SecureRandom.hex,
            amount_type: "maximum",
            amount: mandate_amount,
            start_date: Time.current.to_i,
            interval: "sporadic",
            supported_types: ["india"]
          }
        }
      }
    }
    mandate_options[:payment_method_options][:card][:mandate_options][:currency] = "usd" if with_currency
    mandate_options
  end
end
