# frozen_string_literal: true

class Order::CreateService
  include Order::ResponseHelpers

  LISTED_CURRENCY_RATE_EXPIRED_MESSAGE = "The listed-currency price changed or expired. Please refresh the page and try again."

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

  # Terminal states a purchase can reach that mean its attempt is over and bought nothing. Used to
  # decide whether the buyer's cart survives a wholly-failed checkout. It lists every way a purchase
  # can end badly at checkout time — an ordinary decline, a declined preorder card authorization, a
  # giftee purchase that could not be created — rather than only the one the current code paths
  # produce, so that a change elsewhere cannot quietly start destroying carts. See the comment at
  # the cart-cleanup branch in `perform` for which of these are reachable today.
  def initialize(params:, buyer: nil)
    @params = params
    @buyer = buyer
  end

  def perform
    common_params = params.except(:line_items)
    line_items = params.fetch(:line_items, []).map do |line_item|
      line_item.key?(:quantity) ? line_item : line_item.merge(quantity: 1)
    end
    line_item_uids = line_items.map { _1[:uid] }
    if line_items.length > Cart::MAX_ALLOWED_CART_PRODUCTS
      invalid_responses = line_item_uids.uniq.index_with do
        error_response("You cannot add more than #{Cart::MAX_ALLOWED_CART_PRODUCTS} products to the cart.")
      end
      return Order.new(purchaser: buyer), invalid_responses, []
    end
    if line_item_uids.any?(&:blank?) || line_item_uids.uniq.length != line_item_uids.length
      invalid_responses = line_item_uids.uniq.index_with do
        error_response("The cart data is invalid. Please refresh and try again.")
      end
      return Order.new(purchaser: buyer), invalid_responses, []
    end

    discount_allocations = compute_discount_allocations(line_items)

    offer_codes = {}

    order = Order.new(purchaser: buyer)
    purchase_responses = {}
    failed_purchases = []
    cart_items = line_items.map { _1.slice(:permalink, :price_cents) }
    spent_once_per_cart_allocations = Set.new

    line_items.each_with_index do |line_item_params, line_item_index|
      submitted_discount_code = line_item_params[:discount_code]
      product = Link.find_by(unique_permalink: line_item_params[:permalink])
      line_item_uid = line_item_params[:uid]

      if product.nil?
        purchase_responses[line_item_uid] = error_response("Product not found")
        next
      end

      if listed_payment_element_requires_signed_rate?(product) && direct_listed_currency_rate_hint(product).nil?
        purchase_responses[line_item_uid] = error_response(LISTED_CURRENCY_RATE_EXPIRED_MESSAGE)
        next
      end

      begin
        allocation = discount_allocations[line_item_uid]
        allocated_discount = allocation&.dig(
          :products_data,
          line_item_uid,
          :discount
        )
        once_per_cart_discount_allocation = nil
        spends_once_per_cart_use = false
        if allocated_discount&.[](:once_per_cart)
          allocation_key = allocation.fetch(:offer_code_ids_by_permalink).fetch(line_item_uid)
          allocated_cents = allocated_discount[:cents].to_i
          if allocated_cents.positive?
            spends_once_per_cart_use = !spent_once_per_cart_allocations.include?(allocation_key)
            line_item_params = if spends_once_per_cart_use
              line_item_params.merge(discount_code: allocation.fetch(:submitted_discount_code))
            else
              line_item_params.except(:discount_code)
            end
            once_per_cart_discount_allocation = {
              offer_code_id: allocation_key,
              amount_cents: allocated_cents,
              allocation_id: allocation.fetch(:allocation_id),
            }
          else
            line_item_params = line_item_params.except(:discount_code)
          end
        end

        purchase_params = build_purchase_params(
          product,
          common_params
            .except(
              :billing_agreement_id, :paypal_order_id, :visual, :stripe_payment_method_id, :stripe_customer_id,
              :stripe_setup_intent_id, :stripe_error, :braintree_transient_customer_store_key,
              :braintree_device_data, :use_existing_card, :paymentToken, :buyer_currency_quote,
              # Client-confirm payment-surface hint consumed by Order::PreparePaymentIntentService
              # (which receives the order params directly from the controller); it is not a
              # Purchase attribute, so letting it through raises ActiveModel::UnknownAttributeError
              # in Purchase::CreateService#build_purchase.
              :payment_element_mount_currency, :payment_method_list_token
            )
            .merge(line_item_params.except(
              :uid, :permalink, :once_per_cart_discount_cents, :once_per_cart_discount_rank,
              :accepts_purchasing_power_parity_discount
            ))
            .merge({ cart_items: })
            .merge(
              offer_code_cart_quantity: line_items
                .select { _1[:permalink] == product.unique_permalink }
                .sum { _1[:quantity].to_i }
            )
        ).merge(
          submitted_pre_discount_price_cents: submitted_pre_discount_price_cents(line_item_params, allocated_discount),
          once_per_cart_discount_allocation:,
          buyer_currency_quote_line_uid: line_item_uid,
          buyer_currency_quote_line_index: line_item_index,
          direct_listed_currency_rate: direct_listed_currency_rate_hint(product)
        )

        # Card params are excluded from build_purchase_params (charging is handled by
        # Charge::CreateService), but RestartAtCheckoutService needs them for UpdaterService
        card_params = common_params.slice(
          :card_data_handling_mode, :stripe_payment_method_id, :paypal_order_id, :billing_agreement_id,
          :braintree_transient_customer_store_key, :braintree_device_data, :stripe_customer_id, :stripe_setup_intent_id
        ).to_h.symbolize_keys.compact

        purchase, error, sca_response = Purchase::CreateService.new(
          product:,
          params: purchase_params.merge(is_part_of_combined_charge: true).merge(card_params).merge(
            buyer_currency_quote: params[:buyer_currency_quote]
          ),
          buyer:
        ).perform

        if sca_response
          # Subscription restart SCA: add the upgrade purchase to the order so the
          # confirm endpoint can find it, and use the `order` key the frontend expects
          if sca_response[:purchase].is_a?(Hash) && (upgrade_purchase = Purchase.find_by_secure_external_id(sca_response[:purchase][:id], scope: "confirm"))
            spent_once_per_cart_allocations << allocation_key if spends_once_per_cart_use
            order.purchases << upgrade_purchase
            order.save!
            sca_response = sca_response.except(:purchase).merge(
              order: {
                id: order.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now),
                stripe_connect_account_id: sca_response.dig(:purchase, :stripe_connect_account_id)
              }
            )
          end
          purchase_responses[line_item_uid] = sca_response
          next
        end

        if error
          purchase_responses[line_item_uid] = error_response(error, purchase:)
          failed_purchases << purchase if purchase&.persisted?
          recovered_allocations = discount_allocations.values.uniq.select do |candidate|
            candidate.dig(:products_data, line_item_uid, :discount, :once_per_cart)
          end
          recovered_allocations.each { restore_once_per_cart_coverage(offer_codes, _1, line_items) }
          if submitted_discount_code.present? && !allocated_discount&.[](:once_per_cart)
            offer_codes[submitted_discount_code] ||= {}
            offer_codes[submitted_discount_code][line_item_uid] = { permalink: product.unique_permalink, quantity: line_item_params[:quantity], discount_code: submitted_discount_code }
          end
        end

        if purchase&.persisted?
          spent_once_per_cart_allocations << allocation_key if spends_once_per_cart_use && error.blank?
          if Purchase::ALL_SUCCESS_STATES.include?(purchase.purchase_state)
            # Pre-existing purchase from subscription restart — don't add to order
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

    if (cart = Cart.fetch_by(user: buyer, browser_guid: params[:browser_guid]))
      # The cart is emptied once the checkout got far enough that the buyer has something to show
      # for it, and kept otherwise so they can retry without rebuilding it by hand.
      #
      # `order.persisted?` alone was not that test. A declined purchase is still saved (so the
      # attempt stays auditable) and then appended to the order, which persists the order — so a
      # checkout where *every* item was declined took this branch and destroyed the cart anyway.
      # A declined card on a multi-item cart is the everyday way to reach that; nothing exotic is
      # needed. `all_items_handled` is not the right test either: it demands every response be a
      # success, but a card that needs 3-D Secure comes back as a not-yet-successful response on a
      # purchase that is perfectly on track, and the buyer is mid-authentication on it.
      #
      # So the question asked here is the narrow one: did anything survive? If the order holds no
      # purchase that is still live, nothing was bought and nothing is pending, and the cart stays.
      #
      # "Failed" has more than one name. An ordinary decline leaves a purchase in `failed`, but a
      # preorder whose card authorization is declined lands in its own terminal state,
      # `preorder_authorization_failed`, and a giftee purchase that cannot be created gets
      # `gift_receiver_purchase_failed` (see the state machine in Purchase). Neither of those can
      # reach this code today — a preorder in a cart goes through the combined-charge path, which
      # leaves it `in_progress` for the confirm step, and a giftee purchase is never appended to
      # the order — so asking only `failed?` would be correct right now. They are listed anyway
      # because the cost of being wrong is destroying a buyer's cart, and the reachability of a
      # state is a property of code elsewhere that can change without anyone looking here.
      #
      # `preorder_concluded_unsuccessfully` is deliberately absent: it is reached much later, when
      # a preorder is released and its card is charged, never during checkout.
      #
      # Any state not listed counts as surviving, so an unfamiliar state errs towards emptying the
      # cart rather than silently keeping one after a real purchase.
      nothing_survived = order.persisted? && order.purchases.any? &&
        order.purchases.all? { Order::OfferCodeRecoveryService::FAILED_PURCHASE_STATES.include?(_1.purchase_state) }

      if order.persisted?
        cart.order = order
        cart.mark_deleted! unless nothing_survived
        cart.save! if cart.changed?
      elsif purchase_responses.any? && purchase_responses.values.all? { _1[:success] }
        cart.mark_deleted!
      end
    end

    offer_codes = offer_codes.map do |offer_code, products|
      service = OfferCodeDiscountComputingService.new(
        normalize_discount_code(offer_code),
        products,
        buyer:,
        key_by_input: true,
        excluding_order: order
      )
      { code: offer_code, products:, result: service.process }
    end.filter_map do |response|
      {
        code: response[:code],
        products: response[:result][:products_data].to_h do |line_item_uid, data|
          [response[:products].fetch(line_item_uid)[:permalink], data[:discount]]
        end,
      } if response[:result][:error_code].blank?
    end
    recovered_offer_codes = Order::OfferCodeRecoveryService.new(order:, failed_purchases:).perform
    offer_codes = Order::OfferCodeRecoveryService.merge_responses(offer_codes, recovered_offer_codes)

    return order, purchase_responses, offer_codes
  end

  private
    def compute_discount_allocations(line_items)
      links_by_permalink = Link.where(unique_permalink: line_items.map { _1[:permalink] }).index_by(&:unique_permalink)
      grouped_items = line_items
        .select { _1[:discount_code].present? }
        .group_by do |item|
          normalized_code = normalize_discount_code(item[:discount_code])
          offer_code = links_by_permalink[item[:permalink]]&.find_offer_code(code: normalized_code)
          offer_code.present? ? [:offer_code, offer_code.id] : [:discount_code, normalized_code]
        end

      allocations_by_uid = {}
      zero_allocations_by_uid = Hash.new { |hash, line_item_uid| hash[line_item_uid] = [] }
      consider_ppp = allocations_consider_ppp?(line_items)
      grouped_items.each do |(group_type, group_value), items|
        items = items.each_with_index.sort_by do |item, index|
          link = links_by_permalink[item[:permalink]]
          [allocation_alternative_savings_cents(item, link, consider_ppp:), link&.unique_permalink.to_s, index]
        end.map(&:first)
        submitted_uids = items.to_set { _1.fetch(:uid) }
        ordered_items = items + line_items.reject { submitted_uids.include?(_1.fetch(:uid)) }
        products = ordered_items.to_h do |item|
          link = links_by_permalink[item[:permalink]]
          product = item.slice(:permalink, :quantity).merge(
            price_cents: submitted_uids.include?(item.fetch(:uid)) ? allocation_capacity_cents(item, link) : 0,
            tip_cents: 0
          )
          [item.fetch(:uid), product]
        end
        service = OfferCodeDiscountComputingService.new(
          normalize_discount_code(items.first[:discount_code]),
          products,
          buyer:,
          key_by_input: true,
          offer_code_id: group_type == :offer_code ? group_value : nil
        )
        allocation = service.process.merge(
          offer_code_ids_by_permalink: service.offer_code_ids_by_permalink,
          submitted_discount_code: items.first[:discount_code],
          allocation_id: SecureRandom.uuid
        )
        items.each { allocations_by_uid[_1.fetch(:uid)] = allocation }
        allocation[:products_data].each do |line_item_uid, product_data|
          discount = product_data[:discount]
          if discount&.[](:once_per_cart) && discount[:cents].to_i.zero?
            zero_allocations_by_uid[line_item_uid] << allocation
          end
        end
      end

      zero_allocations_by_uid.each do |line_item_uid, allocations|
        next if allocations_by_uid.key?(line_item_uid)

        distinct_allocations = allocations.uniq
        allocations_by_uid[line_item_uid] = distinct_allocations.first if distinct_allocations.one?
      end
      allocations_by_uid
    end

    def allocations_consider_ppp?(line_items)
      preferences = line_items
        .select { _1.key?(:accepts_purchasing_power_parity_discount) }
        .map { _1[:accepts_purchasing_power_parity_discount] }
      return true if preferences.empty?

      preferences.any? { ActiveModel::Type::Boolean.new.cast(_1) }
    end

    def allocation_alternative_savings_cents(line_item, product, consider_ppp:)
      return 0 unless product

      full_price = allocation_capacity_cents(line_item, product)
      accepted_offer_savings = accepted_offer_savings_cents(line_item, product, full_price)
      return accepted_offer_savings unless accepted_offer_savings.nil?
      return 0 unless consider_ppp

      ppp_details = product.ppp_details(params[:ip_address])
      return 0 if ppp_details.blank? || full_price.zero?

      discounted_price = [(full_price * ppp_details[:factor]).round, ppp_details[:minimum_price]].max
      full_price - discounted_price
    end

    def accepted_offer_savings_cents(line_item, product, full_price)
      accepted_offer_id = line_item.dig(:accepted_offer, :id)
      return if accepted_offer_id.blank?

      upsell = Upsell.available_to_customers.includes(:offer_code).find_by_external_id(accepted_offer_id)
      return unless upsell&.cross_sell? && upsell.product == product

      discount = upsell.offer_code&.evaluate_for_buyer(buyer, product:)
      return unless discount

      quantity = [Integer(line_item[:quantity], exception: false).to_i, 1].max
      unit_price = full_price / quantity
      discounted_unit_price = if discount[:type] == "fixed"
        [unit_price - discount[:cents].to_i, 0].max
      else
        unit_price - (unit_price * discount[:percents].to_i / 100.0).round
      end
      full_price - discounted_unit_price * quantity
    end

    def allocation_capacity_cents(line_item, product)
      return 0 unless product

      quantity = [Integer(line_item[:quantity], exception: false).to_i, 1].max
      submitted_total = Integer(line_item[:price_cents], exception: false).to_i
      tip_cents = Integer(line_item[:tip_cents], exception: false).to_i
      selected_price = [submitted_total - tip_cents, 0].max / quantity
      recurrence = product.prices.alive.find_by_external_id(line_item[:price_id])&.recurrence if line_item[:price_id].present?
      cart_item = product.cart_item(
        price: selected_price,
        option: Array(line_item[:variants]).first,
        rent: line_item[:is_rental],
        recurrence:,
        quantity:,
        pay_in_installments: line_item[:pay_in_installments],
        force_new_subscription: line_item[:force_new_subscription]
      )
      cart_item[:price] * quantity
    end

    def restore_once_per_cart_coverage(offer_codes, allocation, line_items)
      submitted_discount_code = allocation.fetch(:submitted_discount_code)
      offer_codes[submitted_discount_code] ||= {}
      allocation[:products_data].each_key do |line_item_uid|
        retry_line = line_items.find { _1[:uid] == line_item_uid }
        next unless retry_line

        offer_codes[submitted_discount_code][line_item_uid] = {
          permalink: retry_line[:permalink],
          quantity: retry_line[:quantity],
          discount_code: submitted_discount_code,
        }
      end
    end

    def submitted_pre_discount_price_cents(line_item, discount)
      return unless discount&.[](:once_per_cart) && discount[:type] == "fixed"

      submitted_total = Integer(line_item[:price_cents], exception: false)
      tip_cents = Integer(line_item[:tip_cents], exception: false) || 0
      return if submitted_total.nil? || submitted_total < tip_cents

      submitted_total - tip_cents
    end

    def normalize_discount_code(code)
      OfferCode.normalize_code(code)
    end

    def listed_payment_element_requires_signed_rate?(product)
      return false unless listed_payment_element_mount?(product)

      # Before rates were added to the signed method-list token, local-method Elements already
      # charged their product currency using the live rate. Preserve that rolling-deploy path for
      # a valid token that proves this was an iDEAL/Bancontact/UPI-style surface. Direct-listed
      # card mounts still require the signed rate because their displayed allocation depends on it.
      !method_forced_payment_element_token?(product)
    end

    def listed_payment_element_mount?(product)
      return false if params[:buyer_currency_quote].present?
      return false unless params[:payment_details_source] == PurchasePaymentFlow::PAYMENT_ELEMENT

      mount = params[:payment_element_mount_currency].to_s.downcase
      listed = product.price_currency_type.to_s.downcase
      mount.present? && mount == listed && listed != Currency::USD
    end

    def method_forced_payment_element_token?(product)
      listed = product.price_currency_type.to_s.downcase
      types = Checkout::PaymentMethodListToken.verify(
        params[:payment_method_list_token],
        sellers: cart_sellers
      )
      Array(types).any? do |payment_method_type|
        Checkout::BuyerCurrencyEligibility.forced_currency_for(payment_method_type) == listed
      end
    end

    def direct_listed_currency_rate_hint(product)
      return unless listed_payment_element_mount?(product)

      Checkout::PaymentMethodListToken.direct_listed_currency_rate(
        params[:payment_method_list_token],
        sellers: cart_sellers,
        currency: product.price_currency_type
      )
    end

    def cart_sellers
      @cart_sellers ||= begin
        permalinks = params.fetch(:line_items, []).filter_map { _1[:permalink] }.uniq
        Link.where(unique_permalink: permalinks).includes(:user).map(&:user).uniq
      end
    end

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

      force_new_subscription = purchase_params.delete(:force_new_subscription)
      gift_params = purchase_params.extract!(:giftee_email, :giftee_id, :gift_note)
      # confirmation_token is extracted alongside the other payment-surface hints so it reaches
      # Purchase::CreateService as a service-level param (used to record the client-confirm lane in
      # payment-flow analytics) instead of being treated as a Purchase attribute.
      additional_params = purchase_params.extract!(
        :is_gift, :price_id, :wallet_type, :payment_details_source, :confirmation_token, :perceived_free_trial_duration, :accepted_offer,
        :cart_items, :variants, :bundle_products, :custom_fields, :tip_cents, :call_start_time,
        :pay_in_installments
      )
      {
        purchase: purchase_params,
        gift: gift_params,
        force_new_subscription:,
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
end
