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

    [:price_range, :perceived_price_cents, :perceived_upgrade_price_cents, :quantity].each do |param|
      params[param] = params[param].to_i if params[param]
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

    if is_resubscribing && (subscription.cancelled_by_seller? || product.deleted?)
      return { success: false, error_message: "This subscription cannot be restarted." }
    end

    if is_resubscribing && subscription.is_installment_plan? && subscription.charges_completed?
      return { success: false, error_message: "This installment plan has already been completed and cannot be restarted." }
    end

    result = nil
    terminated_or_scheduled_for_termination = subscription.termination_date.present?

    begin
      ActiveRecord::Base.transaction do
        # Update subscription contact info
        if params[:contact_info].present?
          params[:contact_info][:country] = ISO3166::Country[params[:contact_info][:country]]&.common_name
          original_purchase.is_updated_original_subscription_purchase = true
          original_purchase.update!(params[:contact_info])
        end

        if !same_plan_and_price? || (is_resubscribing && overdue_for_charge)
          subscription.update!(flat_fee_applicable: true) unless subscription.flat_fee_applicable?
        end

        # Update card if necessary
        unless use_existing_card?
          had_saved_card = subscription.credit_card.present?

          # (a) Get chargeable. Return if error
          error_message = get_chargeable
          if error_message.present?
            logger.info("SubscriptionUpdater: Error fetching chargeable for subscription #{subscription.external_id}: #{error_message} ; params: #{params}")
            raise Subscription::UpdateFailed, error_message
          end

          # (b) Create new credit card. Return if error.
          credit_card = CreditCard.create(chargeable, card_data_handling_mode, logged_in_user)

          unless credit_card.errors.empty?
            logger.info("SubscriptionUpdater: Error creating new credit card for subscription #{subscription.external_id}: #{credit_card.errors.full_messages} ; params: #{params}")
            raise Subscription::UpdateFailed, credit_card.errors.messages[:base].first
          end

          # (c) Associate the new card with the subscription
          update_subscription_credit_card!(credit_card)

          # (d) Send email for giftee adding their first card
          if !had_saved_card && subscription.gift? && !is_resubscribing
            CustomerLowPriorityMailer.subscription_giftee_added_card(subscription.id).deliver_later
          end
        end

        unless same_plan_and_price?
          self.new_purchase = subscription.update_current_plan!( # here we have an error
            new_variants: variants,
            new_price: price,
            new_quantity: params[:quantity],
            perceived_price_cents: params[:price_range],
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

        # Do not allow restarting a subscription unless
        # the card used for charging the subscription is supported by the product creator.
        # It's possible that the creator has disconnected their PayPal account,
        # and if the subscription is using PayPal as the payment method, future charges will fail.
        if is_resubscribing &&
          !subscription.link.user.supports_card?(subscription.user&.credit_card&.as_json) &&
          !subscription.link.user.supports_card?(subscription.credit_card.as_json)
          raise Subscription::UpdateFailed, "There is a problem with creator's paypal account, please try again later (your card was not charged)."
        end

        if !apply_plan_change_immediately?
          # If not an upgrade or changing plans during trial period, roll back changes
          # made by `Subscription#update_current_plan!`
          restore_original_purchase!
          # If purchase is missing tier and user is not upgrading, associate default tier.
          original_purchase.update!(variant_attributes: [product.default_tier]) if tiered_membership? && original_purchase.variant_attributes.empty?
        end

        # Restart subscription if necessary
        subscription.resubscribe! if is_resubscribing

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
          else
            result = { success: true, success_message: }
          end
        end
      end
    rescue ActiveRecord::RecordInvalid, Subscription::UpdateFailed => e
      logger.info("SubscriptionUpdater: Error updating subscription #{subscription.external_id}: #{e.message} ; params: #{params}")
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
        logger.info("SubscriptionUpdater: Error updating subscription - perceived prices do not match: id: #{subscription.external_id} ; new_price_cents: #{new_price_cents} ; amount_owed: #{amount_owed} ; params: #{params}")
        raise Subscription::UpdateFailed, "The price just changed! Refresh the page for the updated price."
      end
    end

    def new_price_cents
      new_purchase.present? ? new_purchase.displayed_price_cents : subscription.current_subscription_price_cents
    end

    def get_chargeable
      self.card_data_handling_mode = CardParamsHelper.get_card_data_handling_mode(params)
      self.card_data_handling_error = CardParamsHelper.check_for_errors(params)
      self.chargeable = CardParamsHelper.build_chargeable(params.merge(product_permalink: subscription.link.unique_permalink))

      # return error message if necessary
      if card_data_handling_error.present?
        logger.info("SubscriptionUpdater: Error building chargeable for subscription #{subscription.external_id}: #{card_data_handling_error.error_message} #{card_data_handling_error.card_error_code} ; params: #{params}")
        Rails.logger.error("Card data handling error at update stored card: " \
                           "#{card_data_handling_error.error_message} #{card_data_handling_error.card_error_code}")
        card_data_handling_error.is_card_error? ? PurchaseErrorCode.customer_error_message(card_data_handling_error.error_message) : "There is a temporary problem, please try again (your card was not charged)."
      elsif !chargeable.present?
        "We couldn't charge your card. Try again or use a different card."
      end
    end

    def update_subscription_credit_card!(credit_card)
      subscription.credit_card = credit_card
      subscription.save!
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

      purchase_params.merge!(setup_future_charges: true) if subscription.credit_card_to_charge&.requires_mandate?

      self.upgrade_purchase = subscription.charge!(
        override_params: purchase_params,
        from_failed_charge_email: ActiveModel::Type::Boolean.new.cast(params[:declined]),
        off_session: !subscription.credit_card_to_charge&.requires_mandate?
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
            id: upgrade_purchase.external_id,
            stripe_connect_account_id: upgrade_purchase.merchant_account.is_a_stripe_connect_account? ? upgrade_purchase.merchant_account.charge_processor_merchant_id : nil
          }
        }
      else
        logger.info("SubscriptionUpdater: Error charging user for subscription #{subscription.external_id}: #{error_message} ; params: #{params}")
        raise Subscription::UpdateFailed, error_message
      end
    end

    def send_subscription_updated_api_notification
      return if api_notification_sent
      return unless tiered_membership?
      return if same_plan_and_price?
      unless new_purchase.present?
        Bugsnag.notify("SubscriptionUpdater: new_purchase missing when sending API notification")
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
