# frozen_string_literal: true

class Subscription::UpdaterService
  include CurrencyHelper

  attr_reader :subscription, :gumroad_guid, :params, :logged_in_user, :remote_ip
  attr_accessor :original_purchase, :original_price, :new_purchase, :upgrade_purchase,
                :overdue_for_charge, :is_resubscribing, :is_pending_cancellation,
                :calculate_upgrade_cost_as_of, :prorated_discount_price_cents,
                :card_data_handling_mode, :card_data_handling_error, :chargeable,
                :api_notification_sent

  def initialize(subscription:, params:, logged_in_user:, gumroad_guid:, remote_ip:)
    @subscription = subscription
    @params = params
    @logged_in_user = logged_in_user
    @gumroad_guid = gumroad_guid
    @remote_ip = remote_ip
    @api_notification_sent = false

    [:price_range, :perceived_price_cents, :perceived_upgrade_price_cents, :quantity, :submitted_pre_discount_price_cents].each do |param|
      params[param] = params[param].to_i if params[param]
    end
    if params[:once_per_cart_discount_allocation]
      params[:once_per_cart_discount_allocation] = params[:once_per_cart_discount_allocation].to_h.symbolize_keys
      params[:once_per_cart_discount_allocation][:offer_code_id] = params[:once_per_cart_discount_allocation][:offer_code_id].to_i
      params[:once_per_cart_discount_allocation][:amount_cents] = params[:once_per_cart_discount_allocation][:amount_cents].to_i
    end

    if params[:contact_info].present?
      params[:contact_info] = params[:contact_info].transform_values do |value|
        value == "" ? nil : value
      end
    end
  end

  def perform
    error_message = validate_params
    return { success: false, error_message: } if error_message.present?

    # Store existing, pre-updated values
    self.original_purchase = subscription.original_purchase
    self.original_price = subscription.price
    self.overdue_for_charge = subscription.overdue_for_charge?
    self.is_resubscribing = !subscription.alive?(include_pending_cancellation: false)
    self.is_pending_cancellation = subscription.pending_cancellation?
    self.calculate_upgrade_cost_as_of = Time.current.end_of_day
    self.prorated_discount_price_cents = subscription.prorated_discount_price_cents(calculate_as_of: calculate_upgrade_cost_as_of)

    if is_resubscribing && product.deleted?
      return { success: false, error_message: "This product is no longer available, so this membership can't be restarted." }
    end

    if is_resubscribing && subscription.cancelled_by_seller? && use_existing_card?
      return {
        success: false,
        error_message: "This membership was cancelled by the creator. To continue, please subscribe again from the product page.",
        restart_at_checkout_url: product.long_url,
      }
    end

    if is_resubscribing && subscription.is_installment_plan? && subscription.charges_completed?
      return { success: false, error_message: "This installment plan has already been completed and cannot be restarted." }
    end

    result = nil
    terminated_or_scheduled_for_termination = subscription.termination_date.present?
    had_indian_card_mandate_stop = subscription.renewal_disabled_due_to_indian_card_mandate?
    replacement_card = nil
    had_saved_card = false
    seller_price_changed = is_resubscribing && price_changed?
    plan_or_price_changed = !same_plan_and_price? || seller_price_changed
    original_discount = subscription.original_purchase.purchase_offer_code_discount
    discount_changed = if params[:once_per_cart_discount_allocation].present?
      true
    elsif params[:clear_discount]
      true
    elsif params[:offer_code].present? && original_discount.present?
      params[:offer_code] != original_discount.offer_code ||
        params[:offer_code].amount != original_discount.offer_code_amount ||
        params[:offer_code].is_percent? != original_discount.offer_code_is_percent ||
        params[:offer_code].once_per_cart? != original_discount.once_per_cart? ||
        params[:offer_code].duration_in_billing_cycles != original_discount.duration_in_billing_cycles
    else
      params[:offer_code].present?
    end
    mandate_billing_info_changed = mandate_billing_info_changed?
    check_saved_card_mandate_terms_after_update = (plan_or_price_changed || discount_changed || mandate_billing_info_changed) && use_existing_card? &&
      subscription.india_card_mandate_reliability_enabled? &&
      subscription.credit_card_to_charge&.stripe_charge_processor? &&
      subscription.credit_card_to_charge.requires_mandate?
    mandate_terms_before_update = if check_saved_card_mandate_terms_after_update
      subscription.indian_card_mandate_terms
    end
    saved_card_mandate_terms_changed = false

    begin
      ActiveRecord::Base.transaction do
        # Update subscription contact info
        if params[:contact_info].present?
          params[:contact_info][:country] = ISO3166::Country[params[:contact_info][:country]]&.common_name
          original_purchase.is_updated_original_subscription_purchase = true
          original_purchase.update!(params[:contact_info])
        end

        # Update card if necessary
        unless use_existing_card?
          had_saved_card = subscription.credit_card.present?

          # (a) Get chargeable. Return if error
          error_message = get_chargeable
          if error_message.present?
            logger.info("SubscriptionUpdater: Error fetching chargeable for subscription #{subscription.external_id}: #{error_message}")
            raise Subscription::UpdateFailed, error_message
          end

          # (b) Create new credit card. Return if error.
          replacement_card = CreditCard.create(chargeable, card_data_handling_mode, logged_in_user)

          unless replacement_card.errors.empty?
            logger.info("SubscriptionUpdater: Error creating new credit card for subscription #{subscription.external_id}: #{replacement_card.errors.full_messages}")
            raise Subscription::UpdateFailed, replacement_card.errors.messages[:base].first
          end

          unless indian_card_mandate_validation_required?(replacement_card)
            associate_replacement_card!(replacement_card, had_saved_card:, **validate_indian_card_mandate!(replacement_card))
            replacement_card = nil
          end
        end

        if !same_plan_and_price? || (is_resubscribing && discount_changed) || seller_price_changed
          self.new_purchase = subscription.update_current_plan!(
            new_variants: variants,
            new_price: price,
            new_quantity: params[:quantity],
            perceived_price_cents: purchase_perceived_price_cents(original_discount),
            offer_code: params[:offer_code],
            clear_discount: params[:clear_discount],
            clear_deleted_discount: should_clear_original_discount?,
            authenticated_offer_code_buyer: logged_in_user,
            submitted_pre_discount_price_cents: params[:submitted_pre_discount_price_cents] || params[:price_range],
            once_per_cart_discount_allocation: params[:once_per_cart_discount_allocation],
          )
          subscription.reload

        end

        if !same_plan_and_price? || overdue_for_charge
          # Validate that prices matches what the user was shown for prorated upgrade
          # price and ongoing subscription price. Skip this step if the plan is not
          # changing.
          validate_perceived_prices_match

          # delete pending plan changes
          subscription.subscription_plan_changes.alive.update_all(deleted_at: Time.current)
        end

        if replacement_card.present?
          mandate_validation = validate_indian_card_mandate!(replacement_card)
          associate_replacement_card!(replacement_card, had_saved_card:, **mandate_validation)
        end

        # Do not allow a restart or renewal resume when the payment method that
        # future charges will use is no longer supported by the product creator.
        #
        # We check `Subscription#credit_card_to_charge` — the same card recurring
        # charges use (it prefers the subscription's own card over the user's
        # default card) — so a supported default card on the user can't mask an
        # unsupported card stored on the subscription itself. Subscriptions with
        # no chargeable card (e.g. free memberships) have nothing to reject, and
        # a new payment method supplied at checkout has already been validated
        # and associated with the subscription above, so it is covered here too.
        if is_resubscribing || had_indian_card_mandate_stop
          card_to_charge = subscription.credit_card_to_charge
          if card_to_charge.present? && !subscription.link.user.supports_card?(card_to_charge.as_json)
            error_message = if card_to_charge.charge_processor_id == PaypalChargeProcessor.charge_processor_id
              "There is a problem with creator's PayPal account, please try again later (your card was not charged)."
            else
              "The payment method saved on this membership is no longer supported by the creator. Please use a different payment method (your card was not charged)."
            end
            raise Subscription::UpdateFailed, error_message
          end

          validate_saved_indian_card_mandate! if use_existing_card?
        end

        if !apply_plan_change_immediately?
          # If not an upgrade or changing plans during trial period, roll back changes
          # made by `Subscription#update_current_plan!`
          restore_original_purchase!
          # If purchase is missing tier and user is not upgrading, associate default tier.
          if tiered_membership? && original_purchase.variant_attributes.empty?
            default_tier = product.default_tier
            original_purchase.update!(variant_attributes: [default_tier])
            if original_purchase.counts_towards_inventory? && original_purchase.quantity.to_i > 0
              BaseVariant.where(id: default_tier.id).update_all("sales_count_for_inventory_cache = sales_count_for_inventory_cache + #{original_purchase.quantity.to_i}")
            end
          end
        end

        saved_card_mandate_terms_changed = check_saved_card_mandate_terms_after_update &&
          saved_card_update_requires_reauthorization?(
            mandate_terms_before_update,
            plan_or_price_changed:,
            mandate_billing_info_changed:,
            discount_changed:,
            seller_price_changed:
          )
        # Restart subscription if necessary
        subscription.resubscribe! if is_resubscribing

        if saved_card_mandate_terms_changed && !should_charge_user?
          subscription.require_indian_card_mandate_reauthorization!
        end

        if (same_plan_and_price? || subscription.in_free_trial?) && !overdue_for_charge
          send_subscription_updated_api_notification if apply_plan_change_immediately?

          # return if not changing tier or price (and the user isn't resubscribing
          # or changing plan during their free trial period) - no need to update
          # these or charge the user.
          result = { success: true, success_message: }
        else
          if downgrade?
            if !apply_plan_change_immediately?
              plan_change = record_plan_change!
              ContactingCreatorMailer.subscription_downgraded(subscription.id, plan_change.id).deliver_later(queue: "critical")
            end
            send_subscription_updated_api_notification
          end

          # Charge user if necessary
          if should_charge_user?
            result = charge_user!
            if saved_card_mandate_terms_changed && result[:success]
              subscription.require_indian_card_mandate_reauthorization!(notify_buyer: false)
            end
          else
            result = { success: true, success_message: }
          end
        end
      end
    rescue ActiveRecord::RecordInvalid, Subscription::UpdateFailed => e
      logger.info("SubscriptionUpdater: Error updating subscription #{subscription.external_id}: #{e.message}")
      result = { success: false, error_message: e.message }
    end

    subscription.update_flag!(:is_resubscription_pending_confirmation, true, true) if is_resubscribing && result[:requires_card_action]

    if apply_plan_change_immediately? && !same_variants? && result[:success] && !result[:requires_card_action]
      UpdateIntegrationsOnTierChangeWorker.perform_async(subscription.id)
    end

    subscription.send_restart_notifications! if is_resubscribing && result[:success] && !result[:requires_card_action] && terminated_or_scheduled_for_termination

    result
  end

  private
    def validate_params
      return if !tiered_membership? || (variants.present? && price.present?)

      "Please select a valid tier and payment option."
    end

    def validate_perceived_prices_match
      unless new_price_cents == params[:perceived_price_cents] && amount_owed == params[:perceived_upgrade_price_cents]
        logger.info("SubscriptionUpdater: Error updating subscription - perceived prices do not match: id: #{subscription.external_id} ; new_price_cents: #{new_price_cents} ; amount_owed: #{amount_owed}")
        raise Subscription::UpdateFailed, "The price just changed! Refresh the page for the updated price."
      end
    end

    def purchase_perceived_price_cents(original_discount)
      return params[:price_range] unless pwyw? && params[:price_range].present?

      fixed_once_per_cart = if params[:offer_code].present?
        params[:offer_code].is_cents? && params[:offer_code].once_per_cart?
      else
        original_discount.present? && !original_discount.offer_code_is_percent && original_discount.once_per_cart?
      end
      return params[:price_range] unless fixed_once_per_cart

      params[:perceived_price_cents]
    end

    def should_clear_original_discount?
      params[:offer_code].blank? && original_purchase.offer_code&.deleted?
    end

    def new_price_cents
      new_purchase.present? ? new_purchase.displayed_price_cents : current_subscription_price_cents
    end

    def current_subscription_price_cents
      subscription.current_subscription_price_cents(authenticated_offer_code_buyer: logged_in_user)
    end

    def get_chargeable
      self.card_data_handling_mode = CardParamsHelper.get_card_data_handling_mode(params)
      self.card_data_handling_error = CardParamsHelper.check_for_errors(params)
      self.chargeable = CardParamsHelper.build_chargeable(params.merge(product_permalink: subscription.link.unique_permalink))

      # return error message if necessary
      if card_data_handling_error.present?
        logger.info("SubscriptionUpdater: Error building chargeable for subscription #{subscription.external_id}: #{card_data_handling_error.error_message} #{card_data_handling_error.card_error_code}")
        Rails.logger.error("Card data handling error at update stored card: " \
                           "#{card_data_handling_error.error_message} #{card_data_handling_error.card_error_code}")
        card_data_handling_error.is_card_error? ? PurchaseErrorCode.customer_error_message(card_data_handling_error.error_message) : "There is a temporary problem, please try again (your card was not charged)."
      elsif !chargeable.present?
        "We couldn't charge your card. Try again or use a different card."
      end
    end

    def validate_indian_card_mandate!(credit_card)
      return { clear_mandate_stop: true, stripe_mandate_id: nil } unless subscription.india_card_mandate_reliability_enabled?
      return { clear_mandate_stop: true, stripe_mandate_id: nil } unless credit_card.stripe_charge_processor?
      return { clear_mandate_stop: true, stripe_mandate_id: nil } unless credit_card.requires_mandate?
      return { clear_mandate_stop: true, stripe_mandate_id: nil } unless future_subscription_charge?

      merchant_account = subscription.renewal_merchant_account
      setup_intent_id = credit_card.stripe_setup_intent_id
      setup_intent = ChargeProcessor.get_setup_intent(merchant_account, setup_intent_id) if setup_intent_id.present?
      mandate_id = setup_intent&.mandate if setup_intent&.succeeded?
      mandate = ChargeProcessor.get_mandate(merchant_account, mandate_id) if mandate_id.present?
      status = mandate&.status || "missing"
      payment_method_id = credit_card.processor_payment_method_id
      customer_matches = setup_intent&.customer_id == credit_card.stripe_customer_id
      binding_matches = setup_intent&.payment_method_id == payment_method_id &&
        StripeChargeProcessor.mandate_matches_payment_method?(mandate, payment_method_id)
      terms_match = indian_card_setup_intent_terms_match?(setup_intent)

      unless status == "active" && customer_matches && binding_matches && terms_match
        ErrorNotifier.notify(
          "Indian card update rejected without an active e-mandate",
          subscription: subscription.external_id,
          mandate_status: status
        )
        raise Subscription::UpdateFailed, "We could not verify this card for recurring payments. Please try the card again or use a different payment method."
      end

      stripe_chargeable = chargeable&.get_chargeable_for(StripeChargeProcessor.charge_processor_id)
      stripe_chargeable.validated_stripe_mandate_id = mandate.id if stripe_chargeable.respond_to?(:validated_stripe_mandate_id=)
      { clear_mandate_stop: true, stripe_mandate_id: mandate.id }
    rescue ChargeProcessorError => e
      ErrorNotifier.notify(e, subscription: subscription.external_id)
      raise Subscription::UpdateFailed, "We could not verify this card for recurring payments. Please try the card again or use a different payment method."
    end

    def indian_card_mandate_validation_required?(credit_card)
      subscription.india_card_mandate_reliability_enabled? &&
        credit_card.stripe_charge_processor? &&
        credit_card.requires_mandate?
    end

    def indian_card_setup_intent_terms_match?(setup_intent)
      return false unless setup_intent&.usage == "off_session"
      return false unless setup_intent.metadata[:gumroad_subscription_id] == subscription.external_id

      mandate_options = setup_intent.card_mandate_options
      return false if mandate_options.blank?

      expected_terms = subscription.indian_card_mandate_terms(billing_info: params[:contact_info])
      return false if expected_terms.blank?

      mandate_options.amount_type == "maximum" &&
        mandate_options.amount.to_i == expected_terms[:amount] &&
        mandate_options.currency.to_s.downcase == expected_terms[:currency] &&
        mandate_options.reference == StripeChargeProcessor::MANDATE_PREFIX + subscription.external_id &&
        mandate_options.interval == expected_terms[:interval] &&
        mandate_options.interval_count == expected_terms[:interval_count] &&
        Array(mandate_options.supported_types).include?("india")
    end

    def update_subscription_credit_card!(credit_card, clear_mandate_stop: false, stripe_mandate_id: nil)
      subscription.credit_card = credit_card
      if clear_mandate_stop
        subscription.stripe_mandate_id = stripe_mandate_id
        subscription.renewal_disabled_due_to_indian_card_mandate = false
        subscription.indian_card_mandate_requires_reauthorization = false
      end
      subscription.save!
    end

    def associate_replacement_card!(credit_card, had_saved_card:, **mandate_validation)
      update_subscription_credit_card!(credit_card, **mandate_validation)

      if !had_saved_card && subscription.gift? && !is_resubscribing
        CustomerLowPriorityMailer.subscription_giftee_added_card(subscription.id).deliver_later
      end
    end

    def validate_saved_indian_card_mandate!
      return unless subscription.india_card_mandate_reliability_enabled?

      credit_card = subscription.credit_card_to_charge
      return if credit_card.nil?

      unless future_subscription_charge? && credit_card.stripe_charge_processor? && credit_card.requires_mandate?
        subscription.clear_indian_card_mandate_state!(expected_credit_card_id: credit_card.id)
        return
      end

      mandate, status, = subscription.indian_card_mandate_for(credit_card.id)
      unless status == "active"
        raise Subscription::UpdateFailed, "We could not verify this card for recurring payments. Please update the payment method before you restart this subscription."
      end

      subscription.update_renewal_for_indian_card_mandate!(
        "active",
        expected_credit_card_id: credit_card.id,
        mandate_id: mandate.id
      )
    rescue ChargeProcessorError => e
      ErrorNotifier.notify(e, subscription: subscription.external_id)
      raise Subscription::UpdateFailed, "We could not verify this card for recurring payments. Please update the payment method before you restart this subscription."
    end

    def future_subscription_charge?
      subscription.future_subscription_charge?(authenticated_offer_code_buyer: logged_in_user)
    end

    def mandate_billing_info_changed?
      submitted_info = params[:contact_info]&.slice(:country, :state, :zip_code)&.symbolize_keys
      return false if submitted_info.blank?

      stored_info = original_purchase.slice(:country, :state, :zip_code).symbolize_keys
      submitted_info[:country] = ISO3166::Country[submitted_info[:country]]&.common_name || submitted_info[:country]
      stored_info[:country] = ISO3166::Country[stored_info[:country]]&.common_name || stored_info[:country]

      submitted_info.any? { |key, value| value.presence != stored_info[key].presence }
    end

    def saved_card_update_requires_reauthorization?(previous_terms, plan_or_price_changed:, mandate_billing_info_changed:, discount_changed: false, seller_price_changed: false)
      return false unless future_subscription_charge?
      return false unless discount_changed || mandate_billing_info_changed || seller_price_changed || (plan_or_price_changed && apply_plan_change_immediately?)

      billing_info = params[:contact_info] if mandate_billing_info_changed
      subscription.indian_card_mandate_terms(billing_info:) != previous_terms
    end

    def record_plan_change!
      subscription.subscription_plan_changes.create!(
        tier: new_tier,
        recurrence: price.recurrence,
        quantity: new_purchase.quantity,
        perceived_price_cents: new_price_cents,
      )
    end

    def restore_original_purchase!
      if new_purchase.present?
        license = new_purchase.license
        license.update!(purchase_id: original_purchase.id) if license.present?
        email_infos = new_purchase.email_infos
        email_infos.each { |email| email.update!(purchase_id: original_purchase.id) }

        Comment.where(purchase: new_purchase).update_all(purchase_id: original_purchase.id)

        new_purchase.url_redirect.destroy! if new_purchase.url_redirect.present?
        new_purchase.events.destroy_all
        new_purchase.destroy!
        Rails.logger.info("Destroyed purchase #{new_purchase.id}")
      end
      original_purchase.update_flag!(:is_archived_original_subscription_purchase, false, true)
      subscription.last_payment_option.update!(price: original_price)
    end

    def charge_user!
      purchase_params = {
        browser_guid: gumroad_guid,
        perceived_price_cents: amount_owed,
        prorated_discount_price_cents:,
        is_upgrade_purchase: upgrade?
      }

      unless use_existing_card?
        purchase_params.merge!(
          card_data_handling_mode:,
          card_data_handling_error:,
          chargeable:,
        )
      end

      # When a SetupIntent already completed SCA (e.g. multi-seller cart checkout),
      # force off_session: true so the charge references the prior authentication
      # and Stripe doesn't prompt for SCA again.
      setup_intent_authenticated = params[:stripe_setup_intent_id].present?
      saved_payment_method = subscription.credit_card_to_charge

      if !setup_intent_authenticated && saved_payment_method&.requires_mandate?
        purchase_params.merge!(setup_future_charges: true)
      end

      # A saved UPI authorization is renewal-only. Buyer-present updates must not reuse its
      # full-period INR fixing in place of the prorated amount currently shown.
      off_session = setup_intent_authenticated || (!saved_payment_method&.requires_mandate? && !saved_payment_method&.recurring_upi?)

      self.upgrade_purchase = subscription.charge!(
        override_params: purchase_params,
        from_failed_charge_email: ActiveModel::Type::Boolean.new.cast(params[:declined]),
        off_session:,
        authenticated_offer_code_buyer: logged_in_user,
      )

      subscription.unsubscribe_and_fail! if is_resubscribing && !(upgrade_purchase.successful? ||
          (upgrade_purchase.in_progress? && upgrade_purchase.charge_intent&.requires_action?))
      error_message = upgrade_purchase.errors.full_messages.first || upgrade_purchase.error_code

      if error_message.nil? && (upgrade_purchase.successful? || upgrade_purchase.test_successful?)
        send_subscription_updated_api_notification
        subscription.original_purchase.schedule_workflows_for_variants(excluded_variants: original_purchase.variant_attributes) unless same_variants?
        {
          success: true,
          next: logged_in_user && Rails.application.routes.url_helpers.library_purchase_url(upgrade_purchase.external_id, host: "#{PROTOCOL}://#{DOMAIN}"),
          success_message:,
        }
      elsif upgrade_purchase.in_progress? && upgrade_purchase.charge_intent&.requires_action?
        {
          success: true,
          requires_card_action: true,
          client_secret: upgrade_purchase.charge_intent.client_secret,
          purchase: {
            id: upgrade_purchase.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now),
            stripe_connect_account_id: upgrade_purchase.merchant_account.is_a_stripe_connect_account? ? upgrade_purchase.merchant_account.charge_processor_merchant_id : nil
          }
        }
      else
        logger.info("SubscriptionUpdater: Error charging user for subscription #{subscription.external_id}: #{error_message}")
        raise Subscription::UpdateFailed, error_message
      end
    end

    def send_subscription_updated_api_notification
      return if api_notification_sent
      return unless tiered_membership?
      return if same_plan_and_price?
      unless new_purchase.present?
        ErrorNotifier.notify("SubscriptionUpdater: new_purchase missing when sending API notification")
        return
      end

      self.api_notification_sent = true
      subscription.send_updated_notifification_webhook(
        plan_change_type: downgrade? ? "downgrade" : "upgrade",
        effective_as_of: (downgrade? && !apply_plan_change_immediately?) ? subscription.end_time_of_last_paid_period : new_purchase.created_at,
        old_recurrence: original_recurrence,
        new_recurrence: price.recurrence,
        old_tier: original_purchase.tier || product.default_tier,
        new_tier:,
        old_price: original_purchase.displayed_price_cents,
        new_price: new_purchase.displayed_price_cents,
        old_quantity: original_purchase.quantity,
        new_quantity: new_purchase.quantity,
      )
    end

    def product
      @product ||= subscription.link
    end

    def variants
      @variants ||= (params[:variants] || []).map do |id|
        product.base_variants.find_by_external_id(id)
      end.compact
    end

    def new_tier
      variants.first
    end

    def price
      @price ||= product.prices.is_buy.find_by_external_id(params[:price_id])
    end

    def original_recurrence
      original_price.recurrence
    end

    def should_charge_user?
      amount_owed > 0
    end

    def use_existing_card?
      ActiveModel::Type::Boolean.new.cast(params[:use_existing_card])
    end

    def amount_owed
      return new_price_cents if overdue_for_charge || new_plan_is_free?
      return 0 if subscription.in_free_trial? || !upgrade?

      [new_price_cents - prorated_discount_price_cents, min_price_for(product.price_currency_type)].max
    end

    def downgrade?
      !same_plan_and_price? && original_purchase.displayed_price_cents > new_price_cents
    end

    def upgrade?
      !(downgrade? || same_plan_and_price?)
    end

    def same_plan_and_price?
      same_plan? && (!pwyw? || same_pwyw_price?) && same_quantity?
    end

    def same_plan?
      same_variants? && same_recurrence?
    end

    def apply_plan_change_immediately?
      subscription.in_free_trial? || should_charge_user? || new_plan_is_free?
    end

    def same_variants?
      variant_ids = variants.map(&:id)
      if tiered_membership? && original_purchase.variant_attributes.empty?
        # Handle older subscriptions whose original purchases don't have tiers associated.
        # We should allow these to update to the default tier without being charged.
        variant_ids == [product.default_tier.id]
      else
        variant_ids.sort == original_purchase.variant_attributes.to_a.map(&:id).sort
      end
    end

    def same_recurrence?
      !price.present? || original_recurrence == price.recurrence
    end

    def same_quantity?
      original_purchase.quantity == params[:quantity]
    end

    def pwyw?
      variants.any? { |v| v.customizable_price? }
    end

    def price_changed?
      return false if pwyw?
      tier_price = subscription.send(:tier_price)
      return false unless tier_price.present?
      current_subscription_price_cents / original_purchase.quantity != tier_price.price_cents
    end

    def same_pwyw_price?
      pwyw? && original_purchase.displayed_price_cents == params[:perceived_price_cents]
    end

    def tiered_membership?
      subscription.link.is_tiered_membership
    end

    def new_plan_is_free?
      new_price_cents == 0
    end

    def success_message
      if is_resubscribing
        "#{subscription_entity.capitalize} restarted"
      elsif downgrade? && !apply_plan_change_immediately?
        "Your #{subscription_entity} will be updated at the end of your current billing cycle."
      else
        "Your #{subscription_entity} has been updated."
      end
    end

    def subscription_entity
      subscription.is_installment_plan ? "installment plan" : "membership"
    end
end
