# frozen_string_literal: true

class Purchase::CreateService < Purchase::BaseService
  include CurrencyHelper

  RESERVED_URL_PARAMETERS = %w[code wanted referrer email as_modal as_embed debug affiliate_id].freeze
  INVENTORY_LOCK_ACQUISITION_TIMEOUT = 50.seconds

  attr_reader :product, :params, :purchase_params, :gift_params, :buyer
  attr_accessor :purchase, :gift

  def initialize(product:, params:, buyer: nil)
    @product = product
    @params = params
    @purchase_params = params[:purchase]
    @gift_params = params[:gift].presence
    @buyer = buyer
  end

  def perform
    unless @product.allow_parallel_purchases?
      inventory_semaphore = SuoSemaphore.product_inventory(@product.id, acquisition_timeout: INVENTORY_LOCK_ACQUISITION_TIMEOUT)
      inventory_lock_token = inventory_semaphore.lock
      if inventory_lock_token.nil?
        Rails.logger.warn("Could not acquire lock for product_inventory semaphore (product id: #{@product.id})")
        return nil, "Sorry, something went wrong. Please try again."
      end
    end

    begin
      # create gift if necessary
      self.gift = create_gift if is_gift?

      # run pre-build validations
      validate_perceived_price
      validate_zip_code

      # build primary (non-gift) purchase
      self.purchase = build_purchase(purchase_params.merge(gift_given: gift))
      purchase.is_part_of_combined_charge = params[:is_part_of_combined_charge]

      # run post-build validations (to ensure a purchase is present along with the
      # error message, required for rendering errors in bundle checkout)
      validate_perceived_free_trial_params

      if @product.user.account_level_refund_policy_enabled?
        purchase.build_purchase_refund_policy(
          max_refund_period_in_days: @product.user.refund_policy.max_refund_period_in_days,
          title: @product.user.refund_policy.title,
          fine_print: @product.user.refund_policy.fine_print
        )
      elsif @product.product_refund_policy_enabled?
        purchase.build_purchase_refund_policy(
          max_refund_period_in_days: @product.product_refund_policy.max_refund_period_in_days,
          title: @product.product_refund_policy.title,
          fine_print: @product.product_refund_policy.fine_print
        )
      end

      # build pre-order if purchase is for pre-order product & return
      if purchase.is_preorder_authorization
        build_preorder
        return purchase, nil
      elsif product.is_in_preorder_state?
        # This should never happen unless the request is tampered with:
        raise Purchase::PurchaseInvalid, "Something went wrong. Please refresh the page to pre-order the product."
      end

      purchase.is_commission_deposit_purchase = product.native_type == Link::NATIVE_TYPE_COMMISSION

      # associate correct price for membership product
      if product.is_recurring_billing || purchase.is_installment_payment
        # For membership products, params[:price_id] should be provided but if
        # not, or if a price_id is invalid, associate the default price.
        price = params[:price_id].present? ?
          product.prices.alive.find_by_external_id(params[:price_id]) :
          product.default_price

        purchase.price = price || product.default_price
      end

      if purchase.offer_code&.minimum_amount_cents.present?
        valid_items = params[:cart_items]
        valid_items = valid_items.filter { purchase.offer_code.products.find_by(unique_permalink: _1[:permalink]).present? } unless purchase.offer_code.universal
        if valid_items.map { _1[:price_cents].to_i }.sum < purchase.offer_code.minimum_amount_cents
          raise Purchase::PurchaseInvalid, "Sorry, you have not met the offer code's minimum amount."
        end
      end

      if params[:accepted_offer].present?
        upsell = Upsell.available_to_customers.find_by_external_id(params[:accepted_offer][:id])
        raise Purchase::PurchaseInvalid, "Sorry, this offer is no longer available." unless upsell.present?
        if upsell.cross_sell?
          if upsell.not_replace_selected_products?
            cart_product_permalinks = params[:cart_items].reject { _1[:permalink] == product.unique_permalink }.map { _1[:permalink] }
            if upsell.not_is_content_upsell? && (upsell.universal ? product.user.products : upsell.selected_products).where(unique_permalink: cart_product_permalinks).empty?
              raise Purchase::PurchaseInvalid, "The cart does not have any products to which the upsell applies."
            end
          end

          # The original discount is retained if it is better than the upsell
          # discount. The client can't automatically set the upsell discount
          # because it doesn't have a "code". Thus, upsell discount should only
          # be applied when the purchase does not already have a discount code.
          purchase.offer_code ||= upsell.offer_code unless params[:is_purchasing_power_parity_discounted]
        end
        purchase.build_upsell_purchase(
          upsell:,
          selected_product: Link.find_by_external_id(params[:accepted_offer][:original_product_id]),
          upsell_variant: params[:accepted_offer][:original_variant_id].present? ?
            upsell.upsell_variants.alive.find_by(
              selected_variant: BaseVariant.find_by_external_id(params[:accepted_offer][:original_variant_id])
            ) :
            nil
        )
        raise Purchase::PurchaseInvalid, purchase.upsell_purchase.errors.first.message unless purchase.upsell_purchase.valid?
      end

      if params[:tip_cents].present? && params[:tip_cents] > 0
        raise Purchase::PurchaseInvalid, "Tip is not allowed for this product" unless purchase.seller.tipping_enabled? && product.not_is_tiered_membership?

        raise Purchase::PurchaseInvalid, "Tip is too large for this purchase" if (purchase_params[:perceived_price_cents].ceil - params[:tip_cents].floor) < purchase.minimum_paid_price_cents

        purchase.build_tip(value_cents: params[:tip_cents], value_usd_cents: get_usd_cents(product.price_currency_type, params[:tip_cents]))
      end

      validate_bundle_products

      purchase.prepare_for_charge!

      purchase.build_purchase_wallet_type(wallet_type: params[:wallet_type]) if params[:wallet_type].present?

      # Make sure the giftee purchase is created successfully before attempting a charge
      create_giftee_purchase if purchase.is_gift_sender_purchase

      # For bundle purchases we create a payment method and set up future charges for it,
      # then process all purchases off-session in order to avoid multiple SCA pop-ups.
      purchase.charge!(off_session: purchase_params[:is_multi_buy]) unless purchase.is_part_of_combined_charge?

      raise Purchase::PurchaseInvalid, purchase.errors.full_messages[0] if purchase.errors.present?

      # TODO(helen): remove after debugging potential offer code vulnerability
      if purchase.displayed_price_cents == 0 && purchase.offer_code.present?
        logger.info("Free purchase with offer code - purchaser_email: #{purchase.email} | offer_code: #{purchase_params[:discount_code]} | id: #{purchase.id} | params: #{params}")
      end
    rescue Purchase::PurchaseInvalid => e
      if purchase.present?
        handle_purchase_failure
      else
        gift.mark_failed if gift.present?
      end
      return purchase, e.message
    end

    if purchase.requires_sca?
      # Check back later to see if the purchase has been completed. If not, transition to a failed state.
      FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
    else
      handle_purchase_success unless purchase.is_part_of_combined_charge?
    end

    return purchase, nil
  ensure
    inventory_semaphore.unlock(inventory_lock_token) if inventory_lock_token
    handle_purchase_failure if purchase&.persisted? && purchase.in_progress? &&
      !purchase.requires_sca? && !purchase.is_part_of_combined_charge?
  end

  private
    def is_gift?
      !!params[:is_gift]
    end

    def create_gift
      raise Purchase::PurchaseInvalid, "Test gift purchases have not been enabled yet." if buyer == product.user
      raise Purchase::PurchaseInvalid, "You cannot gift a product to yourself. Please try gifting to another email." if giftee_email == purchase_params[:email]
      raise Purchase::PurchaseInvalid, "Gift purchases cannot be on installment plans." if params[:pay_in_installments]

      if product.can_gift?
        gift = product.gifts.build(giftee_email:, gift_note: gift_params[:gift_note], gifter_email: params[:purchase][:email], is_recipient_hidden: gift_params[:giftee_email].blank?)
        error_message = gift.save ? nil : gift.errors.full_messages[0]
        raise Purchase::PurchaseInvalid, error_message if error_message.present?

        gift
      else
        raise Purchase::PurchaseInvalid, "Gifting is not yet enabled for pre-orders."
      end
    end

    def validate_perceived_price
      if purchase_params[:perceived_price_cents] && !Purchase::MAX_PRICE_RANGE.cover?(purchase_params[:perceived_price_cents])
        raise Purchase::PurchaseInvalid, "Purchase price is invalid. Please check the price."
      end
    end

    def validate_zip_code
      country_code_for_validation = purchase_params[:country].presence || purchase_params[:sales_tax_country_code_election]

      if purchase_params[:perceived_price_cents].to_i > 0 && country_code_for_validation == Compliance::Countries::USA.alpha2 && UsZipCodes.identify_state_code(purchase_params[:zip_code]).nil?
        Rails.logger.info("Zip code #{purchase_params[:zip_code]} is invalid, customer email #{purchase_params[:email]}")
        raise Purchase::PurchaseInvalid, "You entered a ZIP Code that doesn't exist within your country."
      end
    end

    def validate_perceived_free_trial_params
      return if is_gift?

      free_trial_params = params[:perceived_free_trial_duration]
      if product.free_trial_enabled?
        if !free_trial_params.present? || !free_trial_params[:amount].present? || !free_trial_params[:unit].present?
          raise Purchase::PurchaseInvalid, "Invalid free trial information provided. Please try again."
        elsif free_trial_params[:amount].to_i != product.free_trial_duration_amount || free_trial_params[:unit] != product.free_trial_duration_unit
          raise Purchase::PurchaseInvalid, "The product's free trial has changed, please refresh the page!"
        end
      elsif free_trial_params.present?
        raise Purchase::PurchaseInvalid, "Invalid free trial information provided. Please try again."
      end
    end

    def validate_bundle_products
      return unless product.is_bundle?

      product.bundle_products.alive.each do |bundle_product|
        if params[:bundle_products].none? { _1[:product_id] == bundle_product.product.external_id && _1[:variant_id] == bundle_product.variant&.external_id && _1[:quantity].to_i == bundle_product.quantity }
          raise Purchase::PurchaseInvalid, "The bundle's contents have changed. Please refresh the page!"
        end
      end
    end

    def build_purchase(params_for_purchase)
      params_for_purchase[:country] = ISO3166::Country[params_for_purchase[:country]]&.common_name

      purchase = product.sales.build(params_for_purchase)
      purchase.affiliate = product.collaborator if product.collaborator.present?
      should_ship = product.is_physical || product.require_shipping
      purchase.country = nil unless should_ship
      purchase.country ||= ISO3166::Country[params_for_purchase[:sales_tax_country_code_election]]&.common_name
      set_purchaser_for(purchase, params_for_purchase[:email])
      purchase.is_installment_payment = params[:pay_in_installments] && product.allow_installment_plan?
      purchase.installment_plan = product.installment_plan if purchase.is_installment_payment
      purchase.save_card = !!params_for_purchase[:save_card] || (product.is_recurring_billing && !is_gift?) || purchase.is_preorder_authorization || purchase.is_installment_payment
      purchase.seller = product.user
      purchase.is_gift_sender_purchase = is_gift? unless params_for_purchase.has_key?(:is_gift_receiver_purchase)
      purchase.offer_code = product.find_offer_code(code: purchase.discount_code.downcase.strip) if purchase.discount_code.present?
      purchase.business_vat_id = (params_for_purchase[:business_vat_id] && params_for_purchase[:business_vat_id].size > 0 ? params_for_purchase[:business_vat_id] : nil)
      purchase.is_original_subscription_purchase = (product.is_recurring_billing && !params_for_purchase[:is_gift_receiver_purchase]) || purchase.is_installment_payment
      purchase.is_free_trial_purchase = product.free_trial_enabled? && !is_gift?
      purchase.should_exclude_product_review = product.free_trial_enabled? && !is_gift?

      Shipment.create(purchase:) if should_ship

      if params[:variants].present?
        params[:variants].each do |external_id|
          variant = product.current_base_variants.find_by_external_id(external_id)
          if variant.present?
            purchase.variant_attributes << variant
          else
            purchase.errors.add(:base, "The product's variants have changed, please refresh the page!")
            raise Purchase::PurchaseInvalid, "The product's variants have changed, please refresh the page!"
          end
        end
      elsif product.is_tiered_membership
        purchase.variant_attributes << product.tiers.first
      elsif product.is_physical && product.skus.is_default_sku.present?
        purchase.variant_attributes << product.skus.is_default_sku.first
      end

      if product.native_type == Link::NATIVE_TYPE_CALL
        start_time = Time.zone.parse(params[:call_start_time] || "")
        duration_in_minutes = purchase.variant_attributes.first&.duration_in_minutes

        if start_time.blank? || duration_in_minutes.blank?
          raise Purchase::PurchaseInvalid, "Please select a start time."
        end

        end_time = start_time + duration_in_minutes.minutes
        purchase.build_call(start_time:, end_time:)
      end

      build_custom_fields(purchase, params[:custom_fields] || [], product:)

      product.bundle_products.alive.each do |bundle_product|
        # Temporarily create custom fields on the bundle purchase in case it can't complete yet due to SCA.
        # The custom fields will be moved to each product purchase when the receipt is generated.
        custom_fields_params = params[:bundle_products]&.find { _1[:product_id] == bundle_product.product.external_id }&.dig(:custom_fields)
        build_custom_fields(purchase, custom_fields_params || [], bundle_product:)
      end

      purchase.url_parameters = parse_url_parameters(params_for_purchase[:url_parameters])
      purchase
    end

    def build_custom_fields(purchase, custom_fields_params, product: nil, bundle_product: nil)
      values = custom_fields_params.to_h { [_1[:id], _1[:value]] }
      (product || bundle_product.product).checkout_custom_fields.each do |custom_field|
        next if custom_field.type == CustomField::TYPE_TEXT && !custom_field.required? && values[custom_field.external_id].blank?
        purchase.purchase_custom_fields << PurchaseCustomField.build_from_custom_field(custom_field:, value: values[custom_field.external_id], bundle_product:)
      end
    end

    def create_giftee_purchase
      giftee_purchase_params = purchase_params.except(:discount_code, :paypal_order_id).merge(
        email: giftee_email,
        is_multi_buy: false,
        is_preorder_authorization: false,
        perceived_price_cents: 0,
        is_gift_sender_purchase: false,
        is_gift_receiver_purchase: true
      )
      giftee_purchase = build_purchase(giftee_purchase_params)
      giftee_purchase.purchaser = giftee_purchaser
      giftee_purchase.gift_received = gift
      giftee_purchase.process!
      raise Purchase::PurchaseInvalid, giftee_purchase.errors.full_messages[0] if giftee_purchase.errors.present?
    end

    def giftee_purchaser
      @_giftee_purchaser ||= gift_params[:giftee_id].present? ? User.alive.find_by_external_id(gift_params[:giftee_id]) : User.alive.by_email(gift_params[:giftee_email]).last
    end

    def giftee_email
      giftee_purchaser&.email || gift_params[:giftee_email]
    end

    def build_preorder
      raise Purchase::PurchaseInvalid, "The product was just released. Refresh the page to purchase it." unless product.is_in_preorder_state?

      self.preorder = product.preorder_link.build_preorder(purchase)
      if purchase.is_part_of_combined_charge?
        purchase.prepare_for_charge!
      else
        preorder.authorize!
        error_message = preorder.errors.full_messages[0]
        if purchase.is_test_purchase?
          preorder.mark_test_authorization_successful!
        elsif error_message.present?
          raise Purchase::PurchaseInvalid, error_message
        elsif purchase.requires_sca?
          # Leave the preorder in `in_progress` state until the the required UI action is completed.
          # Check back later to see if it has been completed. If not, transition to a failed state.
          FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
        else
          preorder.mark_authorization_successful!
        end
      end
    end

    def set_purchaser_for(purchase, purchase_email)
      if buyer.present?
        purchase.purchaser = buyer unless purchase.is_gift_receiver_purchase
      else
        user_from_email = User.find_by(email: purchase_email)
        # This limits test purchase to be done in logged out mode
        if purchase.link.user != user_from_email
          purchase.purchaser = user_from_email
        end
      end
    end

    def parse_url_parameters(url_parameters_string)
      # Turns string into json object and removes reserved paramters
      return nil if url_parameters_string.blank?

      url_parameters_string.tr!("'", "\"") if /{ *'/.match?(url_parameters_string)
      url_params = begin
                     JSON.parse(url_parameters_string)
                   rescue StandardError
                     nil
                   end
      # TODO: Only filter on the frontend once the new checkout experience is rolled out
      if url_params.present?
        url_params.reject do |parameter_name, _parameter_value|
          RESERVED_URL_PARAMETERS.include?(parameter_name)
        end
      end
    end
end

class Purchase::PurchaseInvalid < StandardError; end
