# frozen_string_literal: true

class Order::CreateService
  include Order::ResponseHelpers

  attr_accessor :params, :buyer, :order

  PARAM_TO_ATTRIBUTE_MAPPINGS = {
    friend: :friend_actions,
    plugins: :purchaser_plugins,
    vat_id: :business_vat_id,
    is_preorder: :is_preorder_authorization,
    cc_zipcode: :credit_card_zipcode,
    tax_country_election: :sales_tax_country_code_election
  }.freeze

  PARAMS_TO_REMOVE_IF_BLANK = [:full_name, :email].freeze

  def initialize(params:, buyer: nil)
    @params = params
    @buyer = buyer
  end

  def perform
    common_params = params.except(:line_items)
    line_items = params.fetch(:line_items, [])

    offer_codes = {}

    order = Order.new(purchaser: buyer)
    purchase_responses = {}
    cart_items = line_items.map { _1.slice(:permalink, :price_cents) }

    line_items.each do |line_item_params|
      product = Link.find_by(unique_permalink: line_item_params[:permalink])
      line_item_uid = line_item_params[:uid]

      if product.nil?
        purchase_responses[line_item_uid] = error_response("Product not found")
        next
      end

      if product.is_recurring_billing && !line_item_params[:is_gift]
        existing_subscription_error = check_for_existing_active_subscription(product, common_params[:email])
        if existing_subscription_error
          purchase_responses[line_item_uid] = error_response(existing_subscription_error)
          next
        end
      end

      begin
        purchase_params = build_purchase_params(
          product,
          common_params
            .except(
              :billing_agreement_id, :paypal_order_id, :visual, :stripe_payment_method_id, :stripe_customer_id,
              :stripe_error, :braintree_transient_customer_store_key, :braintree_device_data,
              :use_existing_card, :paymentToken
            )
            .merge(line_item_params.except(:uid, :permalink))
            .merge({ cart_items: })
        )

        purchase, error = Purchase::CreateService.new(
          product:,
          params: purchase_params.merge(is_part_of_combined_charge: true),
          buyer:
        ).perform

        if error
          purchase_responses[line_item_uid] = error_response(error, purchase:)
          if line_item_params[:discount_code].present?
            offer_codes[line_item_params[:discount_code]] ||= {}
            offer_codes[line_item_params[:discount_code]][product.unique_permalink] = { permalink: product.unique_permalink, quantity: line_item_params[:quantity], discount_code: line_item_params[:discount_code] }
          end
        end

        if purchase&.persisted?
          if purchase.successful?
            purchase_responses[line_item_uid] = purchase.purchase_response
          else
            order.purchases << purchase
            order.save!
          end
          if buyer.present? && buyer.email.blank? && !User.where(email: purchase.email).or(User.where(unconfirmed_email: purchase.email)).exists?
            buyer.update!(email: purchase.email)
          end
        end
      end
    end

    if order.persisted? && (cart = Cart.fetch_by(user: buyer, browser_guid: params[:browser_guid]))
      cart.order = order
      cart.mark_deleted!
    end

    offer_codes = offer_codes
                    .map { |offer_code, products| { code: offer_code, result: OfferCodeDiscountComputingService.new(offer_code, products).process } }
                    .filter_map do |response|
      {
        code: response[:code],
        products: response[:result][:products_data].transform_values { _1[:discount] },
      } if response[:result][:error_code].blank?
    end

    return order, purchase_responses, offer_codes
  end

  private
    def build_purchase_params(product, purchase_params)
      purchase_params = purchase_params.to_hash.symbolize_keys

      purchase_params[:purchase] = purchase_params[:purchase].symbolize_keys if purchase_params[:purchase].is_a? Hash
      # merge in params under `purchase` key to top level
      purchase_params.merge!(purchase_params.delete(:purchase)) if purchase_params[:purchase].is_a? Hash

      # rename certain params to match purchase attributes
      PARAM_TO_ATTRIBUTE_MAPPINGS.each do |param, attribute|
        purchase_params[attribute] = purchase_params.delete(param) if purchase_params.has_key?(param)
      end

      # remove certain keys if blank
      PARAMS_TO_REMOVE_IF_BLANK.each do |param|
        purchase_params.delete(param) if purchase_params[param].blank?
      end

      # additional manipulations
      purchase_params[:perceived_price_cents] = purchase_params[:perceived_price_cents].try(:to_i)
      purchase_params[:recommender_model_name] = purchase_params[:recommender_model_name].presence
      purchase_params.delete(:credit_card_zipcode) unless params[:cc_zipcode_required]

      if params[:demo]
        purchase_params.delete(:price_range)
      else
        purchase_params.merge!(
          session_id: params[:session_id],
          ip_country: GeoIp.lookup(params[:ip_address]).try(:country_name),
          ip_state: GeoIp.lookup(params[:ip_address]).try(:region_name),
          is_mobile: params[:is_mobile],
          browser_guid: params[:browser_guid]
        )
      end

      # For some users, the product page reloads without the query string after loading the page. We are yet to identify why this happens.
      # Meanwhile, we can set the url_parameters from referrer when it's missing in the request.
      # Related GH issue: https://github.com/gumroad/web/issues/18190
      # TODO (ershad): Remove parsing url_parameters from referrer after fixing the root issue.
      if purchase_params[:url_parameters].blank? || purchase_params[:url_parameters] == "{}"
        purchase_params[:url_parameters] = parse_url_parameters_from_referrer(product)
      end

      gift_params = purchase_params.extract!(:giftee_email, :giftee_id, :gift_note)
      additional_params = purchase_params.extract!(
        :is_gift, :price_id, :wallet_type, :perceived_free_trial_duration, :accepted_offer,
        :cart_items, :variants, :bundle_products, :custom_fields, :tip_cents, :call_start_time,
        :pay_in_installments
      )
      {
        purchase: purchase_params,
        gift: gift_params,
      }.merge(additional_params.to_hash.deep_symbolize_keys)
    end

    def parse_url_parameters_from_referrer(product)
      return if params[:referrer].blank? || params[:referrer] == "direct"
      return unless params[:referrer].match?(/\/l\/(#{product.unique_permalink}|#{product.custom_permalink})\?[[:alnum:]]+/)

      # Do not parse the params if referrer URL doesn't contain a valid product URL domain
      creator = product.user
      valid_product_url_domains = VALID_REQUEST_HOSTS.map { |domain| "#{PROTOCOL}://#{domain}" }
      valid_product_url_domains << creator.subdomain_with_protocol if creator.subdomain_with_protocol.present?
      valid_product_url_domains << "#{PROTOCOL}://#{creator.custom_domain.domain}" if creator.custom_domain.present?
      return unless valid_product_url_domains.any? { |product_url_domain| params[:referrer].starts_with?(product_url_domain) }

      CGI.parse(URI.parse(params[:referrer]).query).transform_values { |values| values.length <= 1 ? values.first : values }.to_json
    end

    def check_for_existing_active_subscription(product, email)
      user_or_email = buyer || email
      return nil unless user_or_email.present?

      active_subscription = Subscription.active_for_user_and_product(
        user_or_email: user_or_email,
        product: product,
        with_lock: true
      )

      return nil unless active_subscription.present?

      CustomerLowPriorityMailer.already_subscribed_checkout_attempt(active_subscription.id).deliver_later(queue: "low")

      if buyer.present?
        "You already have an active subscription to this membership. Visit your Library to manage it."
      else
        Bugsnag.notify(StandardError.new("Existing subscription checkout attempt")) do |report|
          report.severity = "info"
          report.add_metadata(:subscription, {
                                subscription_id: active_subscription.id,
                                product_id: product.id,
                                email: email
                              })
        end
        "Sorry, something went wrong. Please try again."
      end
    end
end
