# frozen_string_literal: true

class Order::ChargeService
  include Events, Order::ResponseHelpers

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
    purchases_by_seller = order.purchases.group_by(&:seller_id)

    purchases_by_seller.each do |seller_id, seller_purchases|
      charge = order.charges.create!(seller_id:)
      seller_purchases.each do |purchase|
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
      Rails.logger.error("Error charging order (#{order.id}):: #{e.class} => #{e.message} => #{e.backtrace}")
    ensure
      # Ensure all purchases of the charge are transitioned to a terminal state
      # and each line item has a response
      ensure_all_purchases_processed(non_free_seller_purchases)
    end

    charge_responses
  end

  def mark_successful_if_free_or_test_purchase(purchase)
    if purchase.in_progress? && (purchase.free_purchase? || (purchase.is_test_purchase? && !purchase.is_preorder_authorization?))
      Purchase::MarkSuccessfulService.new(purchase).perform
      purchase.handle_recommended_purchase if purchase.was_product_recommended
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

      purchase.check_for_blocked_customer_emails
      purchase.validate_purchasing_power_parity
    end

    chargeable
  end

  def setup_for_future_charges_without_charging(purchases, chargeable, card_already_saved)
    merchant_account = purchases.first.merchant_account

    if merchant_account.stripe_charge_processor? && !card_already_saved
      mandate_options = mandate_options_for_stripe(purchases:, with_currency: true)
      self.setup_intent = ChargeProcessor.setup_future_charges!(merchant_account, chargeable, mandate_options:)

      if setup_intent.present?
        purchases.each do |purchase|
          purchase.update!(processor_setup_intent_id: setup_intent.id)
          purchase.charge.update!(stripe_setup_intent_id: setup_intent.id)
          purchase.credit_card.update!(json_data: { stripe_setup_intent_id: setup_intent.id }) if purchase.credit_card&.requires_mandate?

          if setup_intent.succeeded?
            mark_setup_future_charges_successful(purchase)
          elsif setup_intent.requires_action?
            # Check back later to see if the purchase has been completed. If not, transition to a failed state.
            FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
          else
            purchase.errors.add :base, "Sorry, something went wrong." if purchase.errors.empty?
          end
        end
      end
    else
      purchases.each do |purchase|
        mark_setup_future_charges_successful(purchase)
      end
    end
  end

  def mark_setup_future_charges_successful(purchase)
    return unless purchase.in_progress?

    if purchase.is_free_trial_purchase?
      Purchase::MarkSuccessfulService.new(purchase).perform
      purchase.handle_recommended_purchase if purchase.was_product_recommended
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

    if purchases_to_charge.present?
      amount_cents = purchases_to_charge.sum(&:total_transaction_cents)
      gumroad_amount_cents = purchases_to_charge.sum(&:total_transaction_amount_for_gumroad_cents)
      merchant_account = purchases.first.merchant_account
      seller = User.find(purchases.first.seller_id)
      statement_description = seller.name_or_username
      mandate_options = mandate_options_for_stripe(purchases: purchases_to_charge)

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
      ).perform

      self.charge_intent = charge.charge_intent
      charge.credit_card.update!(json_data: { stripe_payment_intent_id: charge_intent.id }) if charge.credit_card&.requires_mandate?

      if charge_intent&.succeeded?
        purchases.each do |purchase|
          if purchases_to_charge.include?(purchase)
            purchase.paypal_order_id = charge.paypal_order_id if charge.paypal_order_id.present?
            if charge_intent.is_a? StripeChargeIntent
              purchase.build_processor_payment_intent(intent_id: charge_intent.id)
            end
            purchase.save_charge_data(charge_intent.charge, chargeable:)
          end

          next unless purchase.in_progress? && purchase.errors.empty?
          Purchase::MarkSuccessfulService.new(purchase).perform
          purchase.handle_recommended_purchase if purchase.was_product_recommended
        end
      elsif charge_intent&.requires_action?
        purchases_to_charge.each do |purchase|
          if purchase.processor_payment_intent.present?
            purchase.processor_payment_intent.update!(intent_id: charge_intent.id)
          else
            purchase.create_processor_payment_intent!(intent_id: charge_intent.id)
          end
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
        if charge_intent&.requires_action? || setup_intent&.requires_action?
          # Check back later to see if the purchase has been completed. If not, transition to a failed state.
          FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
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
            id: order.external_id,
            stripe_connect_account_id: order.charges.last.merchant_account.is_a_stripe_connect_account? ? order.charges.last.merchant_account.charge_processor_merchant_id : nil
          }
        }
      elsif setup_intent&.requires_action?
        charge_responses[line_item_uid] ||= {
          success: true,
          requires_card_setup: true,
          client_secret: setup_intent.client_secret,
          order: {
            id: order.external_id,
            stripe_connect_account_id: order.purchases.last.merchant_account.is_a_stripe_connect_account? ? order.purchases.last.merchant_account.charge_processor_merchant_id : nil
          }
        }
      else
        charge_responses[line_item_uid] ||= purchase.purchase_response
        purchase.handle_recommended_purchase if purchase.was_product_recommended
      end
    end
  end

  def mandate_options_for_stripe(purchases:, with_currency: false)
    return purchases.first.mandate_options_for_stripe(with_currency:) if purchases.count == 1

    mandate_amount = purchases.max_by(&:total_transaction_cents).total_transaction_cents

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
