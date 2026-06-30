# frozen_string_literal: true

# Lane B (client-confirm) counterpart to Order::ChargeService. Instead of charging a server-built
# PaymentMethod, it inspects the browser's ConfirmationToken pre-charge (card country, for PPP),
# creates an *unconfirmed* PaymentIntent, and persists the order ↔ intent mapping before returning
# the client_secret. The browser confirms the intent and Order::FinalizeConfirmedChargeService
# completes it. Confirm mode is single-seller (one PaymentIntent funds one seller's charge), so
# there is no per-seller loop. Order::ChargeService and the server-confirm path are untouched.
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

    preview = retrieve_payment_method_preview
    return responses if preview.nil?

    apply_previewed_card_country(preview)
    return responses if block_purchasing_power_parity_mismatches

    prepare_unconfirmed_charge
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
      order.purchases.each do |purchase|
        next unless purchase.in_progress? && (purchase.free_purchase? || (purchase.is_test_purchase? && !purchase.is_preorder_authorization?))
        Purchase::MarkSuccessfulService.new(purchase).perform
        responses[line_item_uid_for(purchase)] = purchase.purchase_response
      end
    end

    def retrieve_payment_method_preview
      if confirmation_token.blank?
        fail_purchases_with(GENERIC_CHARGE_ERROR)
        return
      end

      Stripe::ConfirmationToken.retrieve(confirmation_token).payment_method_preview
    rescue Stripe::StripeError => e
      Rails.logger.error("Error retrieving ConfirmationToken for order #{order.id}: #{e.class} => #{e.message}")
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
      return false if purchases_to_charge.none? { |purchase| purchase.errors.any? }

      # One PaymentIntent funds the whole charge, so a single PPP mismatch fails the entire order.
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
    def resolve_merchant_account_and_fees
      purchases_to_charge.each do |purchase|
        purchase.resolve_merchant_account_and_recompute_fees!(StripeChargeProcessor.charge_processor_id)
      end
    end

    def build_charge
      charge = order.charges.create!(seller:)
      charge.update!(merchant_account:, processor: merchant_account.charge_processor_id,
                     amount_cents:, gumroad_amount_cents:)
      purchases_to_charge.each do |purchase|
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
        idempotency_key: "deferred_intent_#{charge.external_id}"
      )
    rescue ChargeProcessorError => e
      Rails.logger.error("Error preparing client-confirm PaymentIntent for order #{order.id}: #{e.class} => #{e.message}")
      nil
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

    # Resolved on each purchase by resolve_merchant_account_and_fees (single-seller, so they share one).
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
      end&.dig(:uid)
    end
end
