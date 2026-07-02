# frozen_string_literal: true

# Prepares a client-confirm charge by inspecting the ConfirmationToken before creating the
# unconfirmed PaymentIntent.
class Order::PreparePaymentIntentService
  include Order::ResponseHelpers

  # The browser's resolved card country is more trustworthy than a client-supplied field.
  CARD_COUNTRY_SOURCE = "stripe"
  GENERIC_CHARGE_ERROR = "There is a temporary problem, please try again (your card was not charged)."

  def initialize(order:, params:, confirmation_token:)
    @order = order
    @params = params
    @confirmation_token = confirmation_token
    @responses = {}
  end

  def perform
    mark_free_or_test_purchases_successful
    return responses if purchases_to_charge.empty?
    return responses if block_multiple_sellers
    return responses if block_ineligible_for_client_confirm
    return responses if block_purchases_with_blocked_customer_emails

    preview = retrieve_payment_method_preview
    return responses if preview.nil?

    apply_previewed_card_country(preview)
    return responses if block_purchasing_power_parity_mismatches

    prepare_unconfirmed_charge
    responses
  rescue => e
    # A partial failure (e.g. a merchant account missing its Charge Processor Merchant ID) must
    # leave every purchase in a terminal state with a buyer-facing error, not stuck in_progress.
    Rails.logger.error("Error preparing client-confirm charge for order #{order.id}: #{e.class} => #{e.message} => #{e.backtrace&.first(15)&.join("\n")}")
    fail_purchases_with(GENERIC_CHARGE_ERROR)
    responses
  end

  private
    attr_reader :order, :params, :confirmation_token, :responses

    def purchases_to_charge
      @purchases_to_charge ||= order.purchases.select do |purchase|
        purchase.in_progress? && purchase.errors.empty? &&
          !purchase.free_purchase? && !purchase.is_test_purchase? &&
          !purchase.is_free_trial_purchase? && !purchase.is_preorder_authorization?
      end
    end

    def mark_free_or_test_purchases_successful
      free_or_test_purchases.each do |purchase|
        Purchase::MarkSuccessfulService.new(purchase).perform
        responses[line_item_uid_for(purchase)] = purchase.purchase_response
      end
    end

    # Captured before marking (while still in_progress) so build_charge can add them to the seller's
    # charge, mirroring Order::ChargeService so the finalize receipt covers free items too.
    def free_or_test_purchases
      @free_or_test_purchases ||= order.purchases.select do |purchase|
        purchase.in_progress? && (purchase.free_purchase? || (purchase.is_test_purchase? && !purchase.is_preorder_authorization?))
      end
    end

    # One ConfirmationToken funds one PaymentIntent, so re-check the single-seller constraint
    # server-side before charging a crafted cart.
    def block_multiple_sellers
      return false if purchases_to_charge.map(&:seller_id).uniq.one?

      Rails.logger.error("Multi-seller client-confirm prepare blocked for order #{order.id}")
      fail_purchases_with(GENERIC_CHARGE_ERROR)
      true
    end

    # The charge path — not the browser — is the authority on client-confirm eligibility. Re-check the
    # cart shape server-side so a crafted #prepare (a recurring/commission/connect cart the endpoint
    # otherwise doesn't gate), or one the presenter mounted from different signals, is rejected with a
    # logged reason instead of building a deferred intent with no valid payment_method_types.
    def block_ineligible_for_client_confirm
      return false if payment_method_resolution.client_confirm_eligible?

      Rails.logger.error("Client-confirm ineligible cart blocked for order #{order.id}: #{payment_method_resolution.fallback_reason}")
      fail_purchases_with(GENERIC_CHARGE_ERROR)
      true
    end

    def retrieve_payment_method_preview
      if confirmation_token.blank?
        fail_purchases_with(GENERIC_CHARGE_ERROR)
        return
      end

      Stripe::ConfirmationToken.retrieve(confirmation_token).payment_method_preview
    rescue Stripe::StripeError => e
      Rails.logger.error("Error retrieving ConfirmationToken for order #{order.id}: #{e.class} => #{e.message} => #{e.backtrace&.first(15)&.join("\n")}")
      fail_purchases_with(GENERIC_CHARGE_ERROR)
      nil
    end

    def apply_previewed_card_country(preview)
      card_country = preview.card&.country
      purchases_to_charge.each do |purchase|
        purchase.card_country = card_country
        purchase.card_country_source = CARD_COUNTRY_SOURCE
      end
    end

    def block_purchasing_power_parity_mismatches
      purchases_to_charge.each(&:validate_purchasing_power_parity)
      fail_all_purchases_when_any_errored
    end

    # Server-confirm checkout runs this at charge time; client-confirm combined charges skip it at
    # create time, so run it before creating the PaymentIntent.
    def block_purchases_with_blocked_customer_emails
      purchases_to_charge.each(&:check_for_blocked_customer_emails)
      fail_all_purchases_when_any_errored
    end

    # One PaymentIntent funds the whole charge, so a single failed purchase fails the entire order.
    def fail_all_purchases_when_any_errored
      return false if purchases_to_charge.none? { |purchase| purchase.errors.any? }

      purchases_to_charge.each do |purchase|
        purchase.errors.add(:base, GENERIC_CHARGE_ERROR) if purchase.errors.empty?
        Purchase::MarkFailedService.new(purchase).perform
        responses[line_item_uid_for(purchase)] = error_response(purchase.errors.first&.message, purchase:)
      end
      true
    end

    def prepare_unconfirmed_charge
      resolve_merchant_account_and_fees
      charge = build_charge
      charge_intent = create_unconfirmed_intent(charge)
      return fail_purchases_with(GENERIC_CHARGE_ERROR) if charge_intent.nil?

      persist_intent_mapping(charge, charge_intent)
      schedule_abandonment_checks
      build_confirmation_responses(charge_intent)
    end

    # Must run before amount_cents/gumroad_amount_cents are summed: it resolves the seller's merchant
    # account and recomputes fees so the Stripe processor fee (excluded at create time) is included.
    # Single-seller (enforced above), so resolve the account once and reuse it across purchases.
    def resolve_merchant_account_and_fees
      first, *rest = purchases_to_charge
      first.resolve_merchant_account_and_recompute_fees!(StripeChargeProcessor.charge_processor_id)
      rest.each do |purchase|
        purchase.resolve_merchant_account_and_recompute_fees!(StripeChargeProcessor.charge_processor_id, merchant_account: first.merchant_account)
      end
    end

    def build_charge
      charge = order.charges.create!(seller:)
      charge.update!(merchant_account:, processor: merchant_account.charge_processor_id,
                     amount_cents:, gumroad_amount_cents:, client_confirmed: true)
      # Add the seller's already-successful free/test purchases alongside the paid ones, so
      # finalize's send_charge_receipts covers them (Order::ChargeService assigns every purchase in
      # a seller group to its charge). Scoped to this charge's seller so a free item from another
      # seller in a mixed cart isn't misattributed. The charge amount stays paid-only.
      charge_purchases = purchases_to_charge + free_or_test_purchases.select { _1.seller_id == seller.id }
      charge_purchases.each do |purchase|
        purchase.charge = charge
        purchase.save!
      end
      charge
    end

    def create_unconfirmed_intent(charge)
      StripeDeferredPaymentIntent.create(
        merchant_account:,
        amount_cents:,
        amount_for_gumroad_cents: gumroad_amount_cents,
        reference: "#{Charge::COMBINED_CHARGE_PREFIX}#{charge.external_id}",
        description: "Gumroad Charge #{charge.external_id}",
        statement_description: seller.name_or_username,
        transfer_group: charge.id_with_prefix,
        # Scope the key to the ConfirmationToken, which Stripe mints fresh per attempt and never
        # reuses, so retrying this exact create stays idempotent. A key built only from
        # charge.external_id (derived from a database id) collides in Stripe test mode, where
        # idempotency keys persist for 24h across CI runs that reset the database and reuse those ids.
        idempotency_key: "deferred_intent_#{charge.external_id}_#{confirmation_token}",
        payment_method_types: resolved_payment_method_types,
        currency: Checkout::StripePaymentPresenter::CLIENT_CONFIRM_CURRENCY
      )
    rescue ChargeProcessorError => e
      Rails.logger.error("Error preparing client-confirm PaymentIntent for order #{order.id} charge #{charge.external_id}: #{e.class} => #{e.message} => #{e.backtrace&.first(15)&.join("\n")}")
      nil
    end

    # Non-nil once block_ineligible_for_client_confirm has passed: the deferred intent's
    # payment_method_types must equal the Payment Element's or Stripe rejects the ConfirmationToken.
    def resolved_payment_method_types
      payment_method_resolution.payment_method_types
    end

    # Recompute eligibility and the method set from server-owned purchases, never a client-supplied
    # list. Single-seller is already enforced by block_multiple_sellers, so resolve for that one seller.
    def payment_method_resolution
      # setup_for_future is intentionally omitted (defaults to false): purchases_to_charge already
      # excludes is_free_trial_purchase? and is_preorder_authorization? items, so a setup-only cart
      # surfaces here as empty and exits at the top-level empty guard before this runs — there is no
      # setup_flow-eligible purchase left to resolve. If purchases_to_charge ever admits a
      # "setup + charge" product type not flagged as free-trial/preorder, pass setup_for_future here.
      @payment_method_resolution ||= Checkout::PaymentMethodResolver.new(
        sellers: [seller],
        recurring: purchases_to_charge.any? { _1.link.is_recurring_billing? },
        commission: purchases_to_charge.any? { _1.link.native_type == Link::NATIVE_TYPE_COMMISSION }
      ).resolve
    end

    # Persist the mapping before responding so a webhook arriving before the browser returns can
    # still resolve the order via Charge#stripe_payment_intent_id or ProcessorPaymentIntent#intent_id.
    def persist_intent_mapping(charge, charge_intent)
      charge.charge_intent = charge_intent
      charge.stripe_payment_intent_id = charge_intent.id
      charge.save!
      purchases_to_charge.each { |purchase| purchase.create_processor_payment_intent!(intent_id: charge_intent.id) }
    end

    def schedule_abandonment_checks
      purchases_to_charge.each do |purchase|
        FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
      end
    end

    def build_confirmation_responses(charge_intent)
      envelope = {
        success: true,
        requires_payment_confirmation: true,
        client_secret: charge_intent.client_secret,
        order: {
          id: order.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now),
          stripe_connect_account_id: merchant_account.is_a_stripe_connect_account? ? merchant_account.charge_processor_merchant_id : nil
        }
      }
      purchases_to_charge.each { |purchase| responses[line_item_uid_for(purchase)] = envelope }
    end

    def fail_purchases_with(message)
      purchases_to_charge.each do |purchase|
        purchase.errors.add(:base, message) if purchase.errors.empty?
        purchase.error_code = PurchaseErrorCode::STRIPE_UNAVAILABLE if purchase.error_code.blank?
        Purchase::MarkFailedService.new(purchase).perform
        responses[line_item_uid_for(purchase)] = error_response(purchase.errors.first&.message, purchase:)
      end
    end

    # Resolved on each purchase by resolve_merchant_account_and_fees; client-confirm has one seller.
    def merchant_account
      @merchant_account ||= purchases_to_charge.first.merchant_account
    end

    def seller
      @seller ||= User.find(purchases_to_charge.first.seller_id)
    end

    def amount_cents
      @amount_cents ||= purchases_to_charge.sum(&:total_transaction_cents)
    end

    def gumroad_amount_cents
      @gumroad_amount_cents ||= purchases_to_charge.sum(&:total_transaction_amount_for_gumroad_cents)
    end

    def line_item_uid_for(purchase)
      params[:line_items].find do |line_item|
        purchase.link.unique_permalink == line_item[:permalink] &&
          (line_item[:variants].blank? || purchase.variant_attributes.first&.external_id == line_item[:variants]&.first)
      end&.dig(:uid) || cart_item_uid_for(purchase)
    end

    # Fallback when a purchase matches no line item in params (e.g. a bundle child): mirror the
    # browser's getCartItemUid ("permalink variantId") and finalize's cart_item_uid so the response
    # is never stored under a nil key, which silently drops it and collides across purchases.
    def cart_item_uid_for(purchase)
      "#{purchase.link.unique_permalink} #{purchase.variant_attributes.first&.external_id}"
    end
end
