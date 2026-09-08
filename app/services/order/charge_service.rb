# frozen_string_literal: true

class Order::ChargeService
  include Events, Order::ResponseHelpers
  include CurrencyHelper

  attr_accessor :order, :params, :charge_intent, :setup_intent, :charge_responses, :account_setup_intents

  def initialize(order:, params:)
    @order = order
    @params = params
    @charge_responses = {}
    @account_setup_intents = {}
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
            purchase.credit_card.store_stripe_setup_intent_id!(merchant_account, setup_intent.id)
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

  # Multi-seller carts charge off-session; an India card with no SetupIntent yet
  # must register its e-mandate here or Stripe rejects the charge as
  # payment_intent_mandate_invalid (gp#2437).
  def register_india_mandate_for_off_session_cart!(purchases, chargeable, merchant_account, mandate_options)
    if chargeable.stripe_setup_intent_id.present?
      existing_si = ChargeProcessor.get_setup_intent(merchant_account, chargeable.stripe_setup_intent_id)
      if existing_si.present? && (existing_si.succeeded? || existing_si.requires_action?) &&
         setup_intent_belongs_to_chargeable?(existing_si, chargeable, purchases, merchant_account) &&
         setup_intent_covers_mandate_options?(existing_si, mandate_options)
        self.setup_intent = existing_si
        bind_connect_payment_method!(chargeable, existing_si, merchant_account)
        # Resume/confirm keys off processor_setup_intent_id on this cart's purchases. A reused
        # pending SI from an earlier abandoned checkout must still be linked here or ConfirmService
        # cannot find the waiting group after the buyer authenticates.
        purchases.each do |purchase|
          purchase.update!(processor_setup_intent_id: existing_si.id)
          purchase.charge&.update!(stripe_setup_intent_id: existing_si.id)
          purchase.mark_indian_card_mandate_registration! if purchase.credit_card&.requires_mandate?
        end
        credit_card = purchases.first&.credit_card
        credit_card&.store_stripe_setup_intent_id!(merchant_account, existing_si.id) if credit_card&.requires_mandate?
        return
      end
      chargeable.stripe_setup_intent_id = nil
    end

    self.setup_intent = ChargeProcessor.setup_future_charges!(merchant_account, chargeable, mandate_options:)
    return unless setup_intent.present?

    # setup_future_charges! may clone another Connect PM inside prepare!; bind to the SI's PM
    # so a synchronous success charges the same method the mandate was registered on.
    bind_connect_payment_method!(chargeable, setup_intent, merchant_account)
    chargeable.stripe_setup_intent_id = setup_intent.id if chargeable.respond_to?(:stripe_setup_intent_id=)

    purchases.each do |purchase|
      purchase.update!(processor_setup_intent_id: setup_intent.id)
      purchase.charge&.update!(stripe_setup_intent_id: setup_intent.id)
      purchase.mark_indian_card_mandate_registration! if purchase.credit_card&.requires_mandate?
    end

    # Store in the merchant-scoped map so later groups on the same account find it via
    # to_chargeable, and renewals resolve the right SI per account.
    credit_card = purchases.first&.credit_card
    credit_card&.store_stripe_setup_intent_id!(merchant_account, setup_intent.id) if credit_card&.requires_mandate?

    if !setup_intent.requires_action? && !setup_intent.succeeded?
      purchases.each do |purchase|
        next unless purchase.errors.empty?
        purchase.error_code = PurchaseErrorCode::INDIA_CARD_MANDATE_MISSING
        purchase.errors.add :base, "We couldn't authorize your card for this payment. Please try again or use a different payment method."
      end
    end
  end

  # When reusing a SetupIntent whose mandate is bound to a specific Connect PM, prepare!
  # will have cloned a fresh PM that lacks the mandate. Point the chargeable at the SI's PM.
  # Reused SetupIntents must belong to this chargeable's customer/payment method. Otherwise a
  # caller could supply another buyer's SI id and receive that intent's client_secret.
  def setup_intent_belongs_to_chargeable?(setup_intent, chargeable, purchases, merchant_account)
    setup_intent_id = setup_intent.try(:id) || chargeable.try(:stripe_setup_intent_id)
    # Only the merchant-scoped map is trusted. The legacy scalar can be copied from checkout
    # params into CreditCard.create, so it must not authorize reuse by itself.
    card = purchases.filter_map { |purchase| purchase.credit_card }.first
    if card&.requires_mandate? && setup_intent_id.present?
      ids = card.json_data.to_h["stripe_setup_intent_ids"]
      account_key = merchant_account.is_a_stripe_connect_account? ? merchant_account.charge_processor_merchant_id : "platform"
      if ids.is_a?(Hash) && ids[account_key].to_s == setup_intent_id.to_s
        return true
      end
    end

    si_customer = setup_intent.try(:customer_id)
    si_pm = setup_intent.try(:payment_method_id)
    chargeable_customer = chargeable.respond_to?(:stripe_charge_params) ? chargeable.stripe_charge_params[:customer] : nil
    chargeable_customer ||= chargeable.try(:customer_id)
    chargeable_pm = chargeable.try(:payment_method_id)

    return true if si_customer.present? && chargeable_customer.present? && si_customer.to_s == chargeable_customer.to_s
    return true if si_pm.present? && chargeable_pm.present? && si_pm.to_s == chargeable_pm.to_s
    false
  end

  # A stored SetupIntent is only reusable when its mandate still covers this charge's cap and
  # currency. Otherwise Stripe rejects the off-session debit and the buyer sees a dead end.
  def setup_intent_covers_mandate_options?(setup_intent, mandate_options)
    needed = mandate_options&.dig(:payment_method_options, :card, :mandate_options)
    return true if needed.blank?

    needed_amount = needed[:amount] || needed["amount"]
    needed_currency = (needed[:currency] || needed["currency"]).to_s.downcase.presence
    return true if needed_amount.blank?

    registered = setup_intent.try(:card_mandate_options)
    if registered.present?
      registered_amount = registered[:amount] || registered["amount"] || registered.try(:amount)
      registered_currency = (registered[:currency] || registered["currency"] || registered.try(:currency)).to_s.downcase.presence
      return false if registered_amount.present? && registered_amount.to_i < needed_amount.to_i
      return false if needed_currency.present? && registered_currency.present? && registered_currency != needed_currency
      return true
    end

    mandate_id = setup_intent.try(:mandate)
    return false if mandate_id.blank?

    true
  rescue StandardError => e
    Rails.logger.info("SetupIntent mandate coverage check failed: #{e.class} => #{e.message}")
    false
  end

  def bind_connect_payment_method!(chargeable, si, merchant_account)
    return unless merchant_account.is_a_stripe_connect_account? && si.payment_method_id.present?
    # prepare! attaches the SI's Connect PM to a connected Customer and includes that customer
    # on the subsequent charge params; use_connected alone leaves an unattached clone.
    chargeable.stripe_setup_intent_id = si.id if chargeable.respond_to?(:stripe_setup_intent_id=)
    if chargeable.respond_to?(:prepare_with_trusted_setup_intent!)
      chargeable.prepare_with_trusted_setup_intent!
    elsif chargeable.respond_to?(:use_connected_account_payment_method!)
      chargeable.use_connected_account_payment_method!(si.payment_method_id)
    end
  end

  # Locks the buyer-currency quote for an India off-session group BEFORE its mandate is
  # registered, holding the token to the same eligibility and per-charge equality checks
  # Charge::CreateService enforces when the group is charged (possibly only after the buyer's
  # 3DS, via Order::ConfirmService — hence setup_future_charges: false, off_session: true,
  # matching that resume call). Fails closed (returns false) on an invalid token so the buyer
  # is never asked to authenticate a mandate whose charge is already doomed; returns nil with
  # no token, keeping the canonical USD mandate.
  def locked_off_session_mandate_quote(purchases:, merchant_account:, chargeable:, amount_cents:)
    quote_token = params[:buyer_currency_quote].presence
    return if quote_token.blank?

    seller = purchases.first.seller
    decision = Checkout::BuyerCurrencyEligibility.new(
      order:,
      seller:,
      merchant_account:,
      chargeable:,
      purchases:,
      params:,
      setup_future_charges: false,
      off_session: true
    ).decision
    raise Checkout::BuyerCurrencyQuote::InvalidToken, "mandate-registration eligibility fallback (#{decision.fallback_reason})" unless decision.eligible?
    raise Checkout::BuyerCurrencyQuote::InvalidToken, "direct-listed presentment with a quote token present" if decision.direct_listed_amount?
    # Same gate as Charge::CreateService#mandate_options_in_charge_currency: a currency Stripe
    # cannot register an India mandate in must not silently keep a USD mandate here, because
    # the resume charge would still present in that currency and mismatch it.
    unless StripeChargeProcessor.indian_card_mandate_currency_supported?(decision.currency)
      raise Checkout::BuyerCurrencyQuote::InvalidToken, "unsupported India card mandate currency: #{decision.currency}"
    end

    Checkout::BuyerCurrencyQuote.verify!(
      token: quote_token,
      seller:,
      merchant_account:,
      currency: decision.currency,
      canonical_total_cents: amount_cents,
      canonical_line_items: purchases.filter_map do |purchase|
        next if purchase.total_transaction_cents.zero?

        { permalink: purchase.link.unique_permalink, total_cents: purchase.total_transaction_cents }
      end,
      later_charge_canonical_line_items: Purchase::FixLaterChargePresentmentService.canonical_line_items_for(purchases)
    )
  rescue Checkout::BuyerCurrencyQuote::InvalidToken => e
    Rails.logger.info("Buyer currency mandate quote rejected for order #{order.id}: #{e.message}")
    purchases.each do |purchase|
      purchase.errors.add(:base, Charge::CreateService::BUYER_CURRENCY_QUOTE_INVALID_MESSAGE)
      purchase.error_code = PurchaseErrorCode::BUYER_CURRENCY_QUOTE_INVALID
    end
    false
  end

  def off_session_mandate_options_in_quote_currency(mandate_options, locked_quote)
    return mandate_options if locked_quote.blank?

    converted = mandate_options_in_setup_currency(mandate_options, locked_quote)
    inner = converted&.dig(:payment_method_options, :card, :mandate_options)
    return converted if inner.blank? || inner[:currency] != locked_quote.currency

    # The group's charge bills exactly the quote's locked presentment total; the cap's own
    # conversion rounding must never leave it below that or Stripe declines the group's debit.
    capped = inner.merge(amount: [inner[:amount], locked_quote.presentment_total_cents.to_i].max)
    converted.deep_merge(payment_method_options: { card: { mandate_options: capped } })
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
      india_off_session_mandate = off_session && chargeable&.requires_mandate? && merchant_account.stripe_charge_processor?
      if india_off_session_mandate
        account_key = stripe_account_key_for_merchant(merchant_account)
        shared_si = account_setup_intents[account_key]

        if shared_si
          # Another seller group on the same Stripe account already registered this SI.
          self.setup_intent = shared_si
          chargeable.stripe_setup_intent_id = shared_si.id if chargeable.respond_to?(:stripe_setup_intent_id=)
          bind_connect_payment_method!(chargeable, shared_si, merchant_account)
          purchases_to_charge.each do |purchase|
            purchase.update!(processor_setup_intent_id: shared_si.id)
            purchase.charge&.update!(stripe_setup_intent_id: shared_si.id)
            purchase.mark_indian_card_mandate_registration! if purchase.credit_card&.requires_mandate?
          end
        else
          # First group on this account: size the mandate cap to cover all same-account groups.
          setup_mandate_options = combined_account_mandate_options(account_key, purchases_to_charge, mandate_purchases)
          setup_mandate_cap = setup_mandate_options&.dig(:payment_method_options, :card, :mandate_options)
          max_group_charge = max_group_charge_for_account(account_key)
          setup_mandate_cap[:amount] = [setup_mandate_cap[:amount], max_group_charge].max if setup_mandate_cap
          # Convert to the buyer-currency quote before mandate coverage checks so a valid INR
          # SetupIntent is not rejected against canonical USD terms (and a USD mandate is not
          # accepted for an INR charge).
          locked_quote = locked_off_session_mandate_quote(purchases: purchases_to_charge, merchant_account:, chargeable:, amount_cents:)
          return if locked_quote == false
          setup_mandate_options = off_session_mandate_options_in_quote_currency(setup_mandate_options, locked_quote)
          if chargeable.stripe_setup_intent_id.present?
            existing_si = ChargeProcessor.get_setup_intent(merchant_account, chargeable.stripe_setup_intent_id)
            unless existing_si.present? && (existing_si.succeeded? || existing_si.requires_action?) &&
                   setup_intent_belongs_to_chargeable?(existing_si, chargeable, purchases_to_charge, merchant_account) &&
                   setup_intent_covers_mandate_options?(existing_si, setup_mandate_options)
              chargeable.stripe_setup_intent_id = nil
            end
          end
          register_india_mandate_for_off_session_cart!(purchases_to_charge, chargeable, merchant_account, setup_mandate_options)
          account_setup_intents[account_key] = setup_intent if setup_intent.present?
        end
        return if setup_intent&.requires_action? || purchases_to_charge.any? { |purchase| purchase.errors.present? }
      end
      if setup_future_charges && mandate_options.present? && chargeable&.requires_mandate?
        mandate_purchases.each(&:mark_indian_card_mandate_registration!)
      end

      # Only on-session setup_future_charges mints replacement mandate terms on the PI.
      # India off-session groups keep mandate_options locally for marking but pass nil to
      # CreateService so Stripe reuses the SetupIntent's mandate.
      charge_mandate_options = setup_future_charges && !india_off_session_mandate ? mandate_options : nil
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
        # An India off-session group resolves its mandate from the chargeable's SetupIntent;
        # sending mandate_options too would ask Stripe to mint different terms on an
        # off-session charge, which it rejects.
        mandate_options: charge_mandate_options,
        params:,
      ).perform

      self.charge_intent = charge.charge_intent
      # charge_intent is nil when the processor call was rescued (e.g. a quote/settlement
      # mismatch) — Charge::CreateService returns the charge with no intent attached in that case.
      if charge_intent.present? && charge.credit_card&.requires_mandate?
        card_json_data = charge.credit_card.json_data.to_h
        if charge_mandate_options.present?
          # This PaymentIntent registered new mandate terms. Drop this account's old SI so
          # renewals prefer the PI mandate; keep other accounts' SIs in the merchant-scoped map.
          card_json_data = charge.credit_card.json_data_without_setup_intent_for(merchant_account)
        end
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
      elsif charge_intent&.processing?
        # An India off-session debit stays `processing` at Stripe for up to 26h with the debit
        # already scheduled — a failure here would invite a resubmit and a second charge. Same
        # rails as Order::ConfirmService's resume charge: leave the purchases in_progress and
        # let client_confirmed route the intent's payment_intent webhooks into the async
        # finalize/fail handlers.
        charge.update!(client_confirmed: true)
        purchases_to_charge.each do |purchase|
          save_processor_payment_intent!(purchase, charge_intent.id)
          purchase.update!(stripe_status: StripeIntentStatus::PROCESSING)
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
        elsif charge_intent&.processing?
          if purchase.is_free_trial_purchase? || purchase.is_preorder_authorization?
            # Paid sibling debit can stay processing for hours; setup-only lines must not wait
            # on that settlement when their SetupIntent already succeeded (or none was needed).
            if setup_intent.blank? || setup_intent.succeeded?
              mark_setup_future_charges_successful(purchase)
            else
              FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
            end
          else
            Rails.logger.info("Leaving purchase #{purchase.id} in_progress while charge intent #{charge_intent.id} is processing")
          end
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
          intent_id: charge_intent.id,
          intent_type: "payment",
          permalink: purchase.link.unique_permalink,
          order: {
            id: order.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now),
            stripe_connect_account_id: stripe_connect_account_id_for(purchase)
          }
        }
      elsif setup_intent&.requires_action?
        charge_responses[line_item_uid] ||= {
          success: true,
          requires_card_setup: true,
          client_secret: setup_intent.client_secret,
          intent_id: setup_intent.id,
          intent_type: "setup",
          permalink: purchase.link.unique_permalink,
          order: {
            id: order.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now),
            stripe_connect_account_id: stripe_connect_account_id_for(purchase)
          }
        }
      elsif charge_intent&.processing? && purchase.in_progress?
        # Same shape as Order::FinalizeConfirmedChargeService#response_for: the debit is
        # scheduled, so the buyer must see a pending outcome, never a resubmittable failure.
        charge_responses[line_item_uid] ||= { success: true, processing: true, permalink: purchase.link.unique_permalink }
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

  # The pending intent was created on this line item's own merchant account —
  # `order.charges.last` / `order.purchases.last` can belong to a different seller group in a
  # multi-seller cart, handing the browser the wrong Stripe account to confirm on.
  def stripe_connect_account_id_for(purchase)
    merchant_account = purchase.merchant_account
    merchant_account&.is_a_stripe_connect_account? ? merchant_account.charge_processor_merchant_id : nil
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
      charge.present? && charge.settlement_deferrable? &&
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

  def stripe_account_key_for_merchant(merchant_account)
    merchant_account&.is_a_stripe_connect_account? ? merchant_account.charge_processor_merchant_id : "platform"
  end

  # Collect all in-progress non-free purchases on the same Stripe account for combined mandate sizing.
  def combined_account_mandate_options(account_key, local_purchases_to_charge, local_mandate_purchases)
    all_account_purchases = order.purchases.select do |p|
      p.in_progress? && p.errors.empty? &&
        !p.is_free_trial_purchase? && !p.is_preorder_authorization? && !p.is_test_purchase? &&
        stripe_account_key_for_merchant(p.merchant_account) == account_key
    end
    all_account_mandate = order.purchases.select do |p|
      p.in_progress? && p.errors.empty? &&
        stripe_account_key_for_merchant(p.merchant_account) == account_key &&
        (p.is_original_subscription_purchase? || p.is_preorder_authorization? || p.is_upgrade_purchase?)
    end
    mandate_options_for_stripe(purchases: (all_account_purchases | all_account_mandate), with_currency: true)
  end

  def max_group_charge_for_account(account_key)
    order.purchases
      .select { |p| p.in_progress? && p.errors.empty? && stripe_account_key_for_merchant(p.merchant_account) == account_key }
      .reject { |p| p.is_free_trial_purchase? || p.is_preorder_authorization? || p.is_test_purchase? }
      .group_by(&:seller_id)
      .values
      .map { |group| group.sum(&:total_transaction_cents) }
      .max || 0
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
