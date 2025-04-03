# frozen_string_literal: true

module ChargeProcessor
  # Time user has to complete Strong Customer Authentication (enter an OTP, confirm purchase via bank app, etc). Sensible default, not dictated by a payment processor.
  TIME_TO_COMPLETE_SCA = 15.minutes

  NOTIFICATION_CHARGE_EVENT = "charge_event.charge_processor.gumroad"

  DEFAULT_CURRENCY_CODE = Currency::USD.upcase

  DISPLAY_NAME_MAP = {
    StripeChargeProcessor.charge_processor_id => StripeChargeProcessor::DISPLAY_NAME,
    BraintreeChargeProcessor.charge_processor_id => BraintreeChargeProcessor::DISPLAY_NAME,
    PaypalChargeProcessor.charge_processor_id => PaypalChargeProcessor::DISPLAY_NAME,
  }.freeze

  CHARGE_PROCESSOR_CLASS_MAP = {
    StripeChargeProcessor.charge_processor_id => StripeChargeProcessor,
    BraintreeChargeProcessor.charge_processor_id => BraintreeChargeProcessor,
    PaypalChargeProcessor.charge_processor_id => PaypalChargeProcessor,
  }.freeze
  private_constant :CHARGE_PROCESSOR_CLASS_MAP

  # Public: Builds a chargeable using the parameters given.
  # Parameters are specific to the charge processor referenced by the charge processor id.
  def self.get_chargeable_for_params(params, gumroad_guid)
    chargeables = charge_processors.map { |charge_processor| charge_processor.get_chargeable_for_params(params, gumroad_guid) }.compact
    return Chargeable.new(chargeables) if chargeables.present?

    nil
  end

  # Public: Builds a chargeable using the data given.
  def self.get_chargeable_for_data(reusable_tokens,
                                   payment_method_id,
                                   fingerprint,
                                   stripe_setup_intent_id,
                                   stripe_payment_intent_id,
                                   last4,
                                   number_length,
                                   visual,
                                   expiry_month,
                                   expiry_year,
                                   card_type,
                                   country,
                                   zip_code = nil,
                                   merchant_account: nil)
    chargeables = []
    charge_processor_ids.each do |charge_processor_id|
      reusable_token = reusable_tokens[charge_processor_id]
      next unless reusable_token

      chargeables << get_charge_processor(charge_processor_id).get_chargeable_for_data(reusable_token,
                                                                                       payment_method_id,
                                                                                       fingerprint,
                                                                                       stripe_setup_intent_id,
                                                                                       stripe_payment_intent_id,
                                                                                       last4,
                                                                                       number_length,
                                                                                       visual,
                                                                                       expiry_month,
                                                                                       expiry_year,
                                                                                       card_type,
                                                                                       country,
                                                                                       zip_code,
                                                                                       merchant_account:)
    end
    return Chargeable.new(chargeables) if chargeables.present?

    nil
  end

  # Public: Gets a Charge object for a charge.
  # Raises error if the charge id is not known by the charge processor.
  # Returns a Charge object.
  def self.get_charge(charge_processor_id, charge_id, merchant_account: nil)
    get_charge_processor(charge_processor_id).get_charge(charge_id,
                                                         merchant_account:)
  end

  # Public: Searches for the charge on charge processor.
  # Returns the charge processor response object if found (Braintree::Transaction or Stripe::Charge),
  # and returns nil if no charge is found.
  def self.search_charge(charge_processor_id:, purchase:)
    get_charge_processor(charge_processor_id).search_charge(purchase:)
  end

  # Public: Gets a ChargeIntent object given its charge processor ID.
  # Raises an error if the payment intent ID is not known by the charge processor.
  # Returns a ChargeIntent object.
  def self.get_charge_intent(merchant_account, payment_intent_id)
    return if payment_intent_id.blank?
    return unless StripeChargeProcessor.charge_processor_id == merchant_account.charge_processor_id

    get_charge_processor(merchant_account.charge_processor_id).get_charge_intent(payment_intent_id, merchant_account:)
  end

  # Public: Gets a SetupIntent object given its charge processor ID.
  # Raises error if the setup intent id is not known by the charge processor.
  # Returns a SetupIntent object.
  def self.get_setup_intent(merchant_account, setup_intent_id)
    return if setup_intent_id.blank?
    return unless StripeChargeProcessor.charge_processor_id == merchant_account.charge_processor_id

    get_charge_processor(merchant_account.charge_processor_id).get_setup_intent(setup_intent_id, merchant_account:)
  end

  # Public: Creates an intent to charge chargeable in the future.
  #
  # Depending on the implementation this setup intent may require on-session user confirmation.
  #
  # Raises error if the setup is declined or there is a technical failure.
  #
  # Returns a SetupIntent object.
  def self.setup_future_charges!(merchant_account, chargeable, mandate_options: nil)
    return unless StripeChargeProcessor.charge_processor_id == merchant_account.charge_processor_id

    charge_processor = get_charge_processor(merchant_account.charge_processor_id)
    chargeable_for_charge_processor = chargeable.get_chargeable_for(merchant_account.charge_processor_id)

    charge_processor.setup_future_charges!(merchant_account, chargeable_for_charge_processor, mandate_options:)
  end

  # Public: Charges a Chargeable object with funds destined to the merchant account.
  #
  # Depending on the implementation the Gumroad portion of the charge may be automatically funded to
  # Gumroad's merchant account if the merchant account provided is not Gumroad's. The amount that gets
  # funded to Gumroad is defined by `amount_for_gumroad_cents`. It's important this is correctly set to
  # money destined for Gumroad because it will be immutable after the charge is created.
  #
  # Raises error if the charge is declined or there is a technical failure.
  #
  # Returns a ChargeIntent object.
  def self.create_payment_intent_or_charge!(merchant_account, chargeable, amount_cents, amount_for_gumroad_cents,
                                            reference, description,
                                            metadata: nil, statement_description: nil, transfer_group: nil,
                                            off_session: true, setup_future_charges: false, mandate_options: nil)
    charge_processor = get_charge_processor(merchant_account.charge_processor_id)
    chargeable_for_charge_processor = chargeable.get_chargeable_for(merchant_account.charge_processor_id)

    charge_processor.create_payment_intent_or_charge!(merchant_account,
                                                      chargeable_for_charge_processor,
                                                      amount_cents,
                                                      amount_for_gumroad_cents,
                                                      reference,
                                                      description,
                                                      metadata:,
                                                      statement_description:,
                                                      transfer_group:,
                                                      off_session:,
                                                      setup_future_charges:,
                                                      mandate_options:)
  end

  def self.confirm_payment_intent!(merchant_account, charge_intent_id)
    return unless StripeChargeProcessor.charge_processor_id == merchant_account.charge_processor_id

    charge_processor = get_charge_processor(merchant_account.charge_processor_id)
    charge_processor.confirm_payment_intent!(merchant_account, charge_intent_id)
  end

  def self.cancel_payment_intent!(merchant_account, charge_intent_id)
    return unless StripeChargeProcessor.charge_processor_id == merchant_account.charge_processor_id

    charge_processor = get_charge_processor(merchant_account.charge_processor_id)
    charge_processor.cancel_payment_intent!(merchant_account, charge_intent_id)
  end

  def self.cancel_setup_intent!(merchant_account, setup_intent_id)
    return unless StripeChargeProcessor.charge_processor_id == merchant_account.charge_processor_id

    charge_processor = get_charge_processor(merchant_account.charge_processor_id)
    charge_processor.cancel_setup_intent!(merchant_account, setup_intent_id)
  end

  # Public: Refunds a charge. Supports both full and partial refund.
  # If amount_cents is not provided a full refund is performed.
  # If refund fails an error is raised.
  def self.refund!(charge_processor_id, charge_id, amount_cents: nil, merchant_account: nil,
                   paypal_order_purchase_unit_refund: nil,
                   reverse_transfer: true,
                   is_for_fraud: nil)
    get_charge_processor(charge_processor_id).refund!(charge_id,
                                                      amount_cents:,
                                                      merchant_account:,
                                                      paypal_order_purchase_unit_refund:,
                                                      reverse_transfer:,
                                                      is_for_fraud:)
  end

  # Public: Handles a charge event.
  # Called by Charge Processor implementations when the charge processor makes calls to their webhook.
  # Not for application use.
  def self.handle_event(event)
    ActiveSupport::Notifications.instrument(NOTIFICATION_CHARGE_EVENT, charge_event: event)
  end

  # Public: Fights a chargeback by supplying evidence.
  def self.fight_chargeback(charge_processor_id, charge_id, dispute_evidence)
    get_charge_processor(charge_processor_id).fight_chargeback(charge_id, dispute_evidence)
  end

  # Public: Returns where the funds are held for this merchant account.
  # Returns a constant defined in HolderOfFunds.
  def self.holder_of_funds(merchant_account)
    charge_processor_id = merchant_account.charge_processor_id
    get_charge_processor(charge_processor_id).holder_of_funds(merchant_account)
  end

  def self.transaction_url(charge_processor_id, charge_id)
    get_charge_processor(charge_processor_id).transaction_url(charge_id)
  end

  def self.transaction_url_for_seller(charge_processor_id, charge_id, charged_using_gumroad_account)
    return if charge_processor_id.blank? || charge_id.blank? || charged_using_gumroad_account

    transaction_url(charge_processor_id, charge_id)
  end

  def self.transaction_url_for_admin(charge_processor_id, charge_id, charged_using_gumroad_account)
    return if charge_processor_id.blank? || charge_id.blank? || !charged_using_gumroad_account

    transaction_url(charge_processor_id, charge_id)
  end

  def self.charge_processor_success_statuses(charge_processor_id)
    charge_processor_class = CHARGE_PROCESSOR_CLASS_MAP[charge_processor_id]
    return charge_processor_class::VALID_TRANSACTION_STATUSES if charge_processor_class

    []
  end

  def self.get_or_search_charge(purchase)
    return nil unless purchase.charge_processor_id.present?
    if purchase.stripe_transaction_id
      charge = get_charge(purchase.charge_processor_id,
                          purchase.stripe_transaction_id,
                          merchant_account: purchase.merchant_account)
    else
      charge = search_charge(charge_processor_id: purchase.charge_processor_id, purchase:)
      if charge &&
        ChargeProcessor.charge_processor_success_statuses(purchase.charge_processor_id).include?(charge.status) &&
        !charge.is_a?(BaseProcessorCharge) # PaypalChargeProcessor.search_charge already returns a `PaypalCharge` type object
        charge = get_charge_processor(purchase.charge_processor_id).get_charge_object(charge)
      end
    end
    charge
  end

  def self.charge_processor_ids
    CHARGE_PROCESSOR_CLASS_MAP.keys
  end

  private_class_method

  def self.charge_processors
    CHARGE_PROCESSOR_CLASS_MAP.map { |_charge_processor_id, charge_processor_class| charge_processor_class.new }
  end

  def self.get_charge_processor(charge_processor_id)
    charge_processor_class = CHARGE_PROCESSOR_CLASS_MAP[charge_processor_id]
    return charge_processor_class.new if charge_processor_class

    nil
  end
end
