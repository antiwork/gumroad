# frozen_string_literal: true

class StripeChargeProcessor
  include StripeErrorHandler
  extend CurrencyHelper

  DISPLAY_NAME = "Stripe"

  # https://stripe.com/docs/api/charges/object#charge_object-status
  VALID_TRANSACTION_STATUSES = %w(succeeded pending).freeze

  # https://stripe.com/docs/api/refunds/create#create_refund-reason
  REFUND_REASON_FRAUDULENT = "fraudulent"

  MANDATE_PREFIX = "Mandate-"

  REQUEST_MANUAL_3DS_PARAMS = {
    payment_method_options: {
      card: {
        request_three_d_secure: "any"
      }
    }
  }.freeze
  private_constant :REQUEST_MANUAL_3DS_PARAMS

  def self.charge_processor_id
    "stripe"
  end

  def merchant_migrated?(merchant_account)
    merchant_account&.is_a_stripe_connect_account?
  end

  def get_chargeable_for_params(params, _gumroad_guid)
    zip_code = params[:cc_zipcode] if params[:cc_zipcode_required]
    product_permalink = params[:product_permalink]

    if params[:stripe_token].present?
      StripeChargeableToken.new(params[:stripe_token], zip_code, product_permalink:)
    elsif params[:stripe_payment_method_id].present?
      StripeChargeablePaymentMethod.new(params[:stripe_payment_method_id], customer_id: params[:stripe_customer_id],
                                                                           stripe_setup_intent_id: params[:stripe_setup_intent_id],
                                                                           zip_code:, product_permalink:)
    end
  end

  def get_chargeable_for_data(reusable_token, payment_method_id, fingerprint,
                              stripe_setup_intent_id, stripe_payment_intent_id,
                              last4, number_length, visual, expiry_month, expiry_year,
                              card_type, country, zip_code = nil, merchant_account: nil)
    StripeChargeableCreditCard.new(merchant_account, reusable_token, payment_method_id, fingerprint,
                                   stripe_setup_intent_id, stripe_payment_intent_id,
                                   last4, number_length, visual, expiry_month, expiry_year, card_type,
                                   country, zip_code)
  end

  # Ref https://stripe.com/docs/api/charges/list
  # for details of all API parameters used in this method.
  def search_charge(purchase:)
    charges = if purchase.charged_using_stripe_connect_account?
      Stripe::Charge.list({ transfer_group: purchase.charge.present? ? purchase.charge.id_with_prefix : purchase.id },
                          { stripe_account: purchase.merchant_account.charge_processor_merchant_id })
    else
      Stripe::Charge.list(transfer_group: purchase.charge.present? ? purchase.charge.id_with_prefix : purchase.id)
    end
    if charges.present?
      charges.data[0]
    else
      search_charge_by_metadata(purchase:)
    end
  end

  def search_charge_by_metadata(purchase:, last_charge_in_page: nil)
    charges = if last_charge_in_page
      purchase.charged_using_stripe_connect_account? ?
        Stripe::Charge.list({ created: { 'gte': purchase.created_at.to_i }, starting_after: last_charge_in_page, limit: 100 },
                            { stripe_account: purchase.merchant_account.charge_processor_merchant_id }) :
        Stripe::Charge.list(created: { 'gte': purchase.created_at.to_i }, starting_after: last_charge_in_page, limit: 100)
    else
      # List all charges from the 30 second window starting purchase.created_at,
      # and then look for purchase.external_id in the metadata
      # Increase the number of objects to be returned to 100. Limit can range between 1 and 100, and the default is 10.
      purchase.charged_using_stripe_connect_account? ?
        Stripe::Charge.list({ created: { 'gte': purchase.created_at.to_i, 'lte': purchase.created_at.to_i + 30 }, limit: 100 },
                            { stripe_account: purchase.merchant_account.charge_processor_merchant_id }) :
        Stripe::Charge.list(created: { 'gte': purchase.created_at.to_i, 'lte': purchase.created_at.to_i + 30 }, limit: 100)
    end
    find_charge_or_get_next_page(charges, purchase:)
  end

  def find_charge_or_get_next_page(charges, purchase:)
    if charges.present?
      charges.data.each do |charge|
        return charge if charge[:metadata].to_s.include?(purchase.external_id)
      end
      # Stripe returns charges in sorted order, with recent charges listed first.
      # So if there are more than 100 charges in the 30 second window,
      # we would need to fetch them in batches of 100 (newest to oldest)
      # until we find the charge or we run out of charges.
      search_charge_by_metadata(purchase:, last_charge_in_page: charges.data.last) if charges.has_more
    end
  end

  def get_charge(charge_id, merchant_account: nil)
    with_stripe_error_handler do
      if merchant_migrated? merchant_account
        begin
          charge = Stripe::Charge.retrieve({ id: charge_id, expand: %w[balance_transaction application_fee.balance_transaction] }, { stripe_account: merchant_account.charge_processor_merchant_id })
        rescue StandardError => e
          Rails.logger.error("Falling back to retrieving charge from Gumroad due to #{e.inspect}")
          charge = Stripe::Charge.retrieve(id: charge_id, expand: %w[balance_transaction application_fee.balance_transaction])
        end
      else
        charge = Stripe::Charge.retrieve(id: charge_id, expand: %w[balance_transaction application_fee.balance_transaction])
      end

      get_charge_object(charge)
    end
  end

  def get_charge_object(charge)
    if charge[:transfer_data]
      destination_transfer = Stripe::Transfer.retrieve(id: charge.transfer)
      stripe_destination_payment = Stripe::Charge.retrieve({ id: destination_transfer.destination_payment, expand: %w[balance_transaction] },
                                                           { stripe_account: destination_transfer.destination })
    end
    balance_transaction = charge.balance_transaction
    if balance_transaction.is_a?(String)
      merchant_account = Purchase.find(charge.transfer_group).merchant_account rescue nil
      balance_transaction = merchant_account&.is_a_stripe_connect_account? ?
                              Stripe::BalanceTransaction.retrieve({ id: balance_transaction }, { stripe_account: merchant_account.charge_processor_merchant_id }) :
                              Stripe::BalanceTransaction.retrieve({ id: balance_transaction })
    end
    StripeCharge.new(charge, balance_transaction, charge.application_fee.try(:balance_transaction),
                     stripe_destination_payment.try(:balance_transaction), destination_transfer)
  end

  def get_charge_intent(payment_intent_id, merchant_account: nil)
    with_stripe_error_handler do
      if merchant_migrated? merchant_account
        if merchant_account.charge_processor_merchant_id.blank?
          raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} "\
              "but has no Charge Processor Merchant ID."
        end
        payment_intent = Stripe::PaymentIntent.retrieve(payment_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
      else
        payment_intent = Stripe::PaymentIntent.retrieve(payment_intent_id)
      end

      StripeChargeIntent.new(payment_intent:, merchant_account:)
    end
  end

  def get_setup_intent(setup_intent_id, merchant_account: nil)
    with_stripe_error_handler do
      if merchant_migrated? merchant_account
        if merchant_account.charge_processor_merchant_id.blank?
          raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} "\
              "but has no Charge Processor Merchant ID."
        end
        setup_intent = Stripe::SetupIntent.retrieve(setup_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
      else
        setup_intent = Stripe::SetupIntent.retrieve(setup_intent_id)
      end

      StripeSetupIntent.new(setup_intent)
    end
  end

  def setup_future_charges!(merchant_account, chargeable, mandate_options: nil)
    params = {
      payment_method_types: ["card"],
      usage: "off_session"
    }
    params.merge!(chargeable.stripe_charge_params)
    params.merge!(mandate_options) if mandate_options.present?

    # Request 3DS manually when preparing future charges for all Indian cards. Ref: https://github.com/gumroad/web/issues/20783
    chargeable.prepare! # loads the payment method's info, including card country
    params.deep_merge!(REQUEST_MANUAL_3DS_PARAMS) if chargeable.country == Compliance::Countries::IND.alpha2

    with_stripe_error_handler do
      if merchant_migrated? merchant_account
        if merchant_account.charge_processor_merchant_id.blank?
          raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} "\
              "but has no Charge Processor Merchant ID."
        end

        setup_intent = Stripe::SetupIntent.create(params, { stripe_account: merchant_account.charge_processor_merchant_id })
      elsif merchant_account.user
        if merchant_account.charge_processor_merchant_id.blank?
          raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} "\
              "but has no Charge Processor Merchant ID."
        end

        setup_intent = Stripe::SetupIntent.create(params)
      else
        setup_intent = Stripe::SetupIntent.create(params)
      end

      setup_intent.confirm if setup_intent.status == StripeIntentStatus::REQUIRES_CONFIRMATION

      StripeSetupIntent.new(setup_intent)
    end
  end

  def create_payment_intent_or_charge!(merchant_account, chargeable, amount_cents, amount_for_gumroad_cents, reference,
                                       description, metadata: nil, statement_description: nil,
                                       transfer_group: nil, off_session: true, setup_future_charges: false, mandate_options: nil)
    should_setup_future_usage = setup_future_charges && !off_session # attempting to set up future usage during an off-session charge will result in an invalid request

    params = {
      amount: amount_cents,
      currency: "usd",
      description:,
      metadata: metadata || {
        purchase: reference
      },
      transfer_group:,
      payment_method_types: ["card"],
      off_session:,
      setup_future_usage: ("off_session" if should_setup_future_usage)
    }

    params.merge!(confirm: true) if off_session

    params.merge!(mandate_options) if mandate_options.present?

    params.merge!(chargeable.stripe_charge_params)

    # Off-session recurring charges on Indian cards use e-mandates:
    # https://stripe.com/docs/india-recurring-payments?integration=paymentIntents-setupIntents
    if off_session && chargeable.requires_mandate?
      mandate = get_mandate_id_from_chargeable(chargeable, merchant_account)
      params.merge!(mandate:) if mandate.present?
    end

    # Request 3DS manually when preparing future charges for all Indian cards. Ref: https://github.com/gumroad/web/issues/20783
    params.deep_merge!(REQUEST_MANUAL_3DS_PARAMS) if should_setup_future_usage && chargeable.country == Compliance::Countries::IND.alpha2

    if statement_description
      statement_description = statement_description.gsub(%r{[^A-Z0-9./\s]}i, "").to_s.strip[0...22]
      params[:statement_descriptor_suffix] = statement_description if statement_description.present?
    end

    with_stripe_error_handler do
      if merchant_migrated? merchant_account
        if merchant_account.charge_processor_merchant_id.blank?
          raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} "\
              "but has no Charge Processor Merchant ID."
        end
        params[:application_fee_amount] = amount_for_gumroad_cents
        payment_intent = Stripe::PaymentIntent.create(params, { stripe_account: merchant_account.charge_processor_merchant_id })
      elsif merchant_account.user
        if merchant_account.charge_processor_merchant_id.blank?
          raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} "\
              "but has no Charge Processor Merchant ID."
        end
        params[:transfer_data] = {
          destination: merchant_account.charge_processor_merchant_id,
          amount: amount_cents - amount_for_gumroad_cents
        }
        payment_intent = Stripe::PaymentIntent.create(params)
      else
        payment_intent = Stripe::PaymentIntent.create(params)
      end

      payment_intent.confirm if payment_intent.status == StripeIntentStatus::REQUIRES_CONFIRMATION

      StripeChargeIntent.new(payment_intent:, merchant_account:)
    end
  end

  def confirm_payment_intent!(merchant_account, charge_intent_id)
    with_stripe_error_handler do
      if merchant_migrated? merchant_account
        if merchant_account.charge_processor_merchant_id.blank?
          raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} "\
              "but has no Charge Processor Merchant ID."
        end
        payment_intent = Stripe::PaymentIntent.retrieve(charge_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
      else
        payment_intent = Stripe::PaymentIntent.retrieve(charge_intent_id)
      end

      payment_intent.confirm unless payment_intent.status == StripeIntentStatus::SUCCESS

      StripeChargeIntent.new(payment_intent:, merchant_account:)
    end
  end

  # If payment intent is in cancelable state, cancels the payment intent. Otherwise, raises a ChargeProcessorError.
  def cancel_payment_intent!(merchant_account, charge_intent_id)
    with_stripe_error_handler do
      if merchant_migrated? merchant_account
        if merchant_account.charge_processor_merchant_id.blank?
          raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} "\
              "but has no Charge Processor Merchant ID."
        end
        payment_intent = Stripe::PaymentIntent.retrieve(charge_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
      else
        payment_intent = Stripe::PaymentIntent.retrieve(charge_intent_id)
      end

      payment_intent.cancel
    end
  end

  # If setup intent is in cancelable state, cancels the setup intent. Otherwise, raises a ChargeProcessorError.
  def cancel_setup_intent!(merchant_account, setup_intent_id)
    with_stripe_error_handler do
      if merchant_migrated? merchant_account
        if merchant_account.charge_processor_merchant_id.blank?
          raise "Merchant Account #{merchant_account.external_id} assigned to user #{merchant_account.user.external_id} "\
              "but has no Charge Processor Merchant ID."
        end
        payment_intent = Stripe::SetupIntent.retrieve(setup_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
      else
        payment_intent = Stripe::SetupIntent.retrieve(setup_intent_id)
      end

      payment_intent.cancel
    end
  end

  def get_refund(refund_id, merchant_account: nil)
    with_stripe_error_handler do
      if merchant_migrated? merchant_account
        begin
          refund = Stripe::Refund.retrieve({ id: refund_id, expand: %w[balance_transaction] }, { stripe_account: merchant_account.charge_processor_merchant_id })
          charge = Stripe::Charge.retrieve({ id: refund.charge, expand: %w[balance_transaction application_fee.refunds.data.balance_transaction] },
                                           { stripe_account: merchant_account.charge_processor_merchant_id })
        rescue StandardError => e
          Rails.logger.error("Falling back to retrieving refund from Gumroad due to #{e.inspect}")
          refund = Stripe::Refund.retrieve(id: refund_id, expand: %w[balance_transaction])
          charge = Stripe::Charge.retrieve(id: refund.charge, expand: %w[balance_transaction application_fee.refunds.data.balance_transaction])
        end
      else
        refund = Stripe::Refund.retrieve(id: refund_id, expand: %w[balance_transaction])
        charge = Stripe::Charge.retrieve(id: refund.charge, expand: %w[balance_transaction application_fee.refunds.data.balance_transaction])
      end

      destination = charge.destination
      if destination
        application_fee_refund = charge.application_fee.refunds.first if charge.application_fee
        destination_transfer = Stripe::Transfer.retrieve(id: charge.transfer)
        stripe_destination_payment = Stripe::Charge.retrieve({ id: destination_transfer.destination_payment,
                                                               expand: %w[refunds.data.balance_transaction application_fee.refunds] },
                                                             { stripe_account: destination_transfer.destination })
        destination_payment_refund = stripe_destination_payment.refunds.first
        if destination_payment_refund
          balance_transaction_id = destination_payment_refund.balance_transaction
          if balance_transaction_id.is_a?(String)
            destination_payment_refund_balance_transaction = Stripe::BalanceTransaction.retrieve(id: balance_transaction_id)
          else
            destination_payment_refund_balance_transaction = balance_transaction_id
          end
        end
        destination_payment_application_fee_refund = stripe_destination_payment.application_fee.refunds.first if stripe_destination_payment.application_fee
      end
      StripeChargeRefund.new(charge, refund, destination_payment_refund,
                             refund.balance_transaction,
                             application_fee_refund.try(:balance_transaction),
                             destination_payment_refund_balance_transaction,
                             destination_payment_application_fee_refund)
    end
  end

  def refund!(charge_id, amount_cents: nil, merchant_account: nil, reverse_transfer: true, is_for_fraud: nil, **_args)
    if merchant_migrated? merchant_account
      begin
        stripe_charge = Stripe::Charge.retrieve({ id: charge_id }, { stripe_account: merchant_account.charge_processor_merchant_id })
      rescue StandardError => e
        Rails.logger.error "Falling back to retrieve from Gumroad account due to #{e.inspect}"
        stripe_charge = Stripe::Charge.retrieve(charge_id)
      end
    else
      stripe_charge = Stripe::Charge.retrieve(charge_id)
    end

    params = {
      charge: charge_id
    }
    params[:amount] = amount_cents if amount_cents.present?
    params[:reason] = REFUND_REASON_FRAUDULENT if is_for_fraud.present?

    # For Stripe-Connect:
    # Charges (which have a destination):
    # 1. Reverse the transfer that put the money into the creators account
    # 2. Refund Gumroad's fee to the creator
    # We don't reverse the transfer when refunding VAT to the customer,
    # as VAT amount is held by gumroad and not credited to the creator at the time of original charge.
    if stripe_charge.destination && reverse_transfer
      params[:reverse_transfer] = true
      params[:refund_application_fee] = true
    end

    if merchant_migrated? merchant_account
      begin
        params[:refund_application_fee] = false
        stripe_refund = Stripe::Refund.create(params, stripe_account: merchant_account.charge_processor_merchant_id)
      rescue StandardError => e
        Rails.logger.error "Falling back to retrieve from Gumroad account due to #{e.inspect}"
        stripe_refund = Stripe::Refund.create(params)
      end
    else
      stripe_refund = Stripe::Refund.create(params)
    end

    get_refund(stripe_refund.id, merchant_account:)
  rescue Stripe::InvalidRequestError => e
    raise ChargeProcessorAlreadyRefundedError.new("Stripe charge was already refunded. Stripe response: #{e.message}", original_error: e) unless e.message[/already been refunded/].nil?

    raise ChargeProcessorInvalidRequestError.new(original_error: e)
  rescue Stripe::APIConnectionError, Stripe::APIError => e
    raise ChargeProcessorUnavailableError.new("Stripe error while refunding a charge: #{e.message}", original_error: e)
  end

  def self.debit_stripe_account_for_refund_fee(credit:)
    return unless credit.present?
    return if credit.amount_cents == 0
    return unless credit.merchant_account&.charge_processor_merchant_id.present?
    return unless credit.merchant_account.holder_of_funds == HolderOfFunds::STRIPE
    return if credit.merchant_account.country == Compliance::Countries::USA.alpha2
    return if credit.fee_retention_refund&.debited_stripe_transfer.present?

    stripe_account_id = credit.merchant_account.charge_processor_merchant_id
    amount_cents = credit.amount_cents.abs

    # First, try and reverse an internal transfer made from gumroad platform account
    # to the connect account, if possible.
    transfers = credit.user.payments.completed
                      .where(stripe_connect_account_id: stripe_account_id)
                      .order(:created_at)
                      .pluck(:stripe_internal_transfer_id)
    transfer_id = transfers.compact_blank.find do |tr_id|
      tr = Stripe::Transfer.retrieve(tr_id) rescue nil
      tr.present? && (tr.amount - tr.amount_reversed > amount_cents)
    end
    if transfer_id.present?
      transfer_reversal = Stripe::Transfer.create_reversal(transfer_id, { amount: amount_cents })
      refund = credit.fee_retention_refund
      refund.update!(debited_stripe_transfer: transfer_reversal.id) if refund.present?
      destination_refund = Stripe::Refund.retrieve(transfer_reversal.destination_payment_refund,
                                                   stripe_account: stripe_account_id)

      destination_balance_transaction = Stripe::BalanceTransaction.retrieve(destination_refund.balance_transaction,
                                                                            stripe_account: stripe_account_id)
      return destination_balance_transaction.net.abs
    end

    # If no eligible internal transfer was available, reverse a transfer associated with an old purchase.
    # Try and find a transfer older than 120 days. As disputes and refunds are not allowed after 120 days, it's safe to
    # reverse these transfers.
    transfers = Stripe::Transfer.list(destination: stripe_account_id, created: { 'lt': 120.days.ago.to_i }, limit: 100)
    transfer = transfers.find do |tr|
      tr.present? && (tr.amount - tr.amount_reversed > amount_cents)
    end
    if transfer.present?
      transfer_reversal = Stripe::Transfer.create_reversal(transfer.id, { amount: amount_cents })
      refund = credit.fee_retention_refund
      refund.update!(debited_stripe_transfer: transfer_reversal.id) if refund.present?
      destination_refund = Stripe::Refund.retrieve(transfer_reversal.destination_payment_refund,
                                                   stripe_account: stripe_account_id)

      destination_balance_transaction = Stripe::BalanceTransaction.retrieve(destination_refund.balance_transaction,
                                                                            stripe_account: stripe_account_id)
      destination_balance_transaction.net.abs
    end
  end

  def self.debit_stripe_account_for_australia_backtaxes(credit:)
    return unless credit.present?
    return if credit.amount_cents == 0
    return unless credit.backtax_agreement&.jurisdiction == BacktaxAgreement::Jurisdictions::AUSTRALIA
    backtax_agreement = credit.backtax_agreement
    return if backtax_agreement.collected?

    owed_amount_cents_usd = credit.amount_cents.abs
    # Adjust the amount owed if only a partial amount of reversals completed (due to some Stripe failure)
    owed_amount_cents_usd -= backtax_agreement.backtax_collections.sum(:amount_cents_usd) if backtax_agreement.backtax_collections.size > 0

    unless owed_amount_cents_usd > 0
      backtax_agreement.update!(collected: true)
      return
    end

    if credit.merchant_account.holder_of_funds == HolderOfFunds::GUMROAD
      # No Stripe transfer needed. Record the backtax collection and return.
      ActiveRecord::Base.transaction do
        BacktaxCollection.create!(
          user: credit.user,
          backtax_agreement:,
          amount_cents: owed_amount_cents_usd,
          amount_cents_usd: owed_amount_cents_usd,
          currency: "usd",
          stripe_transfer_id: nil
        )
        backtax_agreement.update!(collected: true)
      end

      return
    end

    return unless credit.merchant_account.holder_of_funds == HolderOfFunds::STRIPE
    return unless credit.merchant_account&.charge_processor_merchant_id.present?

    stripe_currency = credit.merchant_account.currency
    stripe_account_id = credit.merchant_account.charge_processor_merchant_id
    stripe_balance = Stripe::Balance.retrieve({ stripe_account: stripe_account_id })
    stripe_available_object = stripe_balance.available.find { |stripe_object| stripe_object.currency == stripe_currency }
    stripe_pending_object = stripe_balance.pending.find { |stripe_object| stripe_object.currency == stripe_currency }

    stripe_balance_amount = stripe_available_object.amount + stripe_pending_object.amount

    if credit.merchant_account.country == Compliance::Countries::USA.alpha2
      # Avoid debiting the customer's bank account if they haven't accumulated enough balance in their Gumroad-controlled Stripe account.
      return unless stripe_balance_amount > owed_amount_cents_usd

      # For US Gumroad-controlled Stripe accounts, we can make new debit transfers.
      # So we transfer the taxes owed amount from the creator's Gumroad-controlled Stripe account to Gumroad's Stripe account.
      transfer = Stripe::Transfer.create({ amount: owed_amount_cents_usd, currency: "usd", destination: STRIPE_PLATFORM_ACCOUNT_ID, },
                                         { stripe_account: stripe_account_id })

      ActiveRecord::Base.transaction do
        BacktaxCollection.create!(
          user: credit.user,
          backtax_agreement:,
          amount_cents: owed_amount_cents_usd,
          amount_cents_usd: owed_amount_cents_usd,
          currency: "usd",
          stripe_transfer_id: transfer.id
        )
        backtax_agreement.update!(collected: true)
      end
    else
      # For non-US Gumroad-controlled Stripe accounts, we cannot make new debit transfers.
      # So we look to reverse historical transfers made from Gumroad's Stripe account to the creator's Gumroad-controlled Stripe account.
      # We look to reverse enough transfers to cover the total amount owed.
      #
      # The historical transfers could have been executed in usd, or the Stripe account's currency, depending on when they were executed.
      # The below algorithm will accumulate transfers of the same currency type — enough to cover the amount owed — and reverse them at the end.
      # All transfers to be reversed will have the same currency type, to avoid inaccuracies due to currency conversion.

      # Determine the owed amount in the Stripe account's currency.
      # Then, avoid debiting the customer's bank account if they haven't accumulated enough balance in their Gumroad-controlled Stripe account.
      owed_amount_in_currency = usd_cents_to_currency(stripe_currency, owed_amount_cents_usd)
      return unless stripe_balance_amount > owed_amount_in_currency

      # Determine the stripe balance amount in usd.
      # Reduce that amount by 5%, as a buffer for possible currency conversion inaccuracies.
      # Then, avoid debiting the customer's bank account if they haven't accumulated enough balance in their Gumroad-controlled Stripe account.
      stripe_balance_amount_cents_usd = get_usd_cents("usd", stripe_balance_amount)
      stripe_balance_amount_cents_usd_reduced_by_five_percent = (stripe_balance_amount_cents_usd - (5.0 / 100) * stripe_balance_amount_cents_usd).round
      return unless stripe_balance_amount_cents_usd_reduced_by_five_percent > owed_amount_cents_usd

      # Each of the `transfers` values below will be an Array of two-element Arrays, like: [["tr_123", 100], ["tr_456", 200], ...]
      # These two-element Arrays represent the transfer ID, and the amount to reverse.
      data = {
        usd: {
          owed: owed_amount_cents_usd,
          transfers: [],
          sum_of_transfer_amounts: 0,
        },
        stripe_currency.to_sym => {
          owed: owed_amount_in_currency,
          transfers: [],
          sum_of_transfer_amounts: 0,
        }
      }

      # First, look for internal transfers made from Gumroad's Stripe account
      # to the creator's Gumroad-controlled Stripe account.
      transfer_ids = credit.user.payments.completed
                           .where(stripe_connect_account_id: stripe_account_id)
                           .order(:created_at)
                           .pluck(:stripe_internal_transfer_id)
      transfer_ids.compact_blank.each do |transfer_id|
        break if data.values.any? { |value| value[:sum_of_transfer_amounts] >= value[:owed] }

        transfer = Stripe::Transfer.retrieve(transfer_id) rescue nil
        calculate_transfer_reversal(transfer, data)
      end

      starting_after = nil
      until data.values.any? { |value| value[:sum_of_transfer_amounts] >= value[:owed] }
        # Next, look for transfers associated with an old purchase.
        # Look for transfers older than 120 days.
        # Disputes and refunds are not allowed after 120 days, so it's safe to reverse such transfers.
        transfers = Stripe::Transfer.list(destination: stripe_account_id, created: { 'lt': 120.days.ago.to_i }, limit: 100, starting_after:)
        break unless transfers.count > 0

        transfers.each do |transfer|
          break if data.values.any? { |value| value[:sum_of_transfer_amounts] >= value[:owed] }

          starting_after = transfer.id
          calculate_transfer_reversal(transfer, data)
        end
      end

      reversal_currency, reversal_data = data.find { |_, value| value[:sum_of_transfer_amounts] >= value[:owed] }
      # Only perform transfers if we can transfer the total amount owed, in full.
      # Avoid making a batch of transfers that would only cover the partial amount owed.
      return unless reversal_currency.present? && reversal_data.present?

      reversal_currency = reversal_currency.to_s

      reversal_data[:transfers].each do |transfer_id, amount_to_reverse|
        transfer_reversal = Stripe::Transfer.create_reversal(transfer_id, { amount: amount_to_reverse })

        BacktaxCollection.create!(
          user: credit.user,
          backtax_agreement:,
          amount_cents: amount_to_reverse,
          amount_cents_usd: get_usd_cents(reversal_currency, amount_to_reverse),
          currency: reversal_currency,
          stripe_transfer_id: transfer_reversal.id
        )
      end

      backtax_agreement.update!(collected: true)
    end
  end

  def fight_chargeback(stripe_charge_id, dispute_evidence, merchant_account: nil)
    return if merchant_migrated? merchant_account

    with_stripe_error_handler do
      charge = Stripe::Charge.retrieve(stripe_charge_id)

      Stripe::Dispute.update(
        charge.dispute,
        evidence: {
          billing_address: dispute_evidence.billing_address,
          customer_email_address: dispute_evidence.customer_email,
          customer_name: dispute_evidence.customer_name,
          customer_purchase_ip: dispute_evidence.customer_purchase_ip,
          product_description: dispute_evidence.product_description,
          receipt: create_dispute_evidence_stripe_file(dispute_evidence.receipt_image),
          service_date: dispute_evidence.purchased_at.to_fs(:formatted_date_full_month),
          shipping_address: dispute_evidence.shipping_address,
          shipping_carrier: dispute_evidence.shipping_carrier,
          shipping_date: dispute_evidence.shipped_at&.to_fs(:formatted_date_full_month),
          shipping_tracking_number: dispute_evidence.shipping_tracking_number,
          uncategorized_text: [
            "The merchant should win the dispute because:\n#{dispute_evidence.reason_for_winning}",
            dispute_evidence.uncategorized_text
          ].compact.join("\n\n"),
          access_activity_log: dispute_evidence.access_activity_log,
          cancellation_policy: create_dispute_evidence_stripe_file(dispute_evidence.cancellation_policy_image),
          cancellation_policy_disclosure: dispute_evidence.cancellation_policy_disclosure,
          refund_policy: create_dispute_evidence_stripe_file(dispute_evidence.refund_policy_image),
          refund_policy_disclosure: dispute_evidence.refund_policy_disclosure,
          cancellation_rebuttal: dispute_evidence.cancellation_rebuttal,
          refund_refusal_explanation: dispute_evidence.refund_refusal_explanation,
          customer_communication: create_dispute_evidence_stripe_file(dispute_evidence.customer_communication_file),
        }
      )
    end
  end

  def holder_of_funds(merchant_account)
    return HolderOfFunds::CREATOR if merchant_account.is_a_stripe_connect_account?
    return HolderOfFunds::STRIPE if merchant_account.user

    HolderOfFunds::GUMROAD
  end

  def self.handle_stripe_event(stripe_event)
    if stripe_event["type"].start_with?("charge.", "payment_intent.payment_failed")
      handle_stripe_charge_event(stripe_event)
    elsif stripe_event["type"].start_with?("capital.")
      handle_stripe_capital_loan_event(stripe_event)
    elsif stripe_event["type"].start_with?("radar.")
      handle_stripe_radar_event(stripe_event)
    end
  end

  def self.handle_stripe_radar_event(stripe_event)
    StripeChargeRadarProcessor.handle_event(stripe_event)
  end

  def self.handle_stripe_capital_loan_event(stripe_event)
    return unless stripe_event["type"] == "capital.financing_transaction.created"

    data = stripe_event["data"]["object"]
    return unless data["type"] == "payment"

    currency = data["details"]["currency"]
    merchant_account = MerchantAccount.find_by(charge_processor_merchant_id: data["account"])
    return unless merchant_account&.currency == currency
    return if merchant_account.is_a_stripe_connect_account?
    return if merchant_account.is_managed_by_gumroad?

    stripe_loan_paydown_id = data["id"]
    amount_cents = -data["details"]["total_amount"].to_i
    return if merchant_account.user.credits.where("json_data->'$.stripe_loan_paydown_id' = ?", stripe_loan_paydown_id).exists?

    if data["details"]["reason"] == "collection" && data["user_facing_description"] == "Forced debit from Stripe Payments"
      Credit.create_for_manual_paydown_on_stripe_loan!(amount_cents:, merchant_account:, stripe_loan_paydown_id:)
    elsif data["details"]["reason"] == "automatic_withholding"
      linked_payment_id = data["details"]["transaction"]["charge"].presence || data["details"]["linked_payment"]
      if linked_payment_id.present?
        linked_payment = Stripe::Charge.retrieve(linked_payment_id, { stripe_account: merchant_account.charge_processor_merchant_id })
        linked_transfer = Stripe::Transfer.retrieve(linked_payment.source_transfer)
        purchase = merchant_account.user.sales.find_by(stripe_transaction_id: linked_transfer.source_transaction)
      end
      Credit.create_for_financing_paydown!(purchase:, amount_cents:, merchant_account:, stripe_loan_paydown_id:)
    end
  end

  def self.handle_stripe_charge_event(stripe_event)
    event = nil

    if stripe_event["type"] == "charge.failed"
      # Charge events are only useful if we can lookup the original purchase. If a charge fails we do not store the
      # charge id on the purchase and therefore the event cannot be looked up. We catch it here and ignore because of this.
      return
    elsif stripe_event["type"].start_with?("charge.dispute.")
      raise "Stripe Event #{stripe_event['id']} does not contain a 'dispute' object." if stripe_event["data"]["object"]["object"] != "dispute"
      raise "Stripe Event #{stripe_event['id']} has no charge id." if stripe_event["data"]["object"]["charge"].nil?
      raise "Stripe Event #{stripe_event['id']} has no created date." if stripe_event["created"].nil?

      # Ignore events telling us a dispute is closed because the charge was refunded.
      # It is no longer possible for these events to access the Dispute, and in any case the funds were refunded and there's
      # nothing useful for us to communicate upstream about the dispute.
      return if stripe_event["type"] == "charge.dispute.closed" && stripe_event["data"]["object"]["status"] == "charge_refunded"

      stripe_dispute_id = stripe_event["data"]["object"]["id"]
      stripe_connect_account_id = stripe_event["user_id"].present? ? stripe_event["user_id"] : stripe_event["account"]
      stripe_dispute = if stripe_connect_account_id.present? && stripe_connect_account_id != Stripe::Account.retrieve.id
        Stripe::Dispute.retrieve({ id: stripe_dispute_id, expand: %w[balance_transactions] }, { stripe_account: stripe_connect_account_id })
      else
        Stripe::Dispute.retrieve(id: stripe_dispute_id, expand: %w[balance_transactions])
      end

      event = ChargeEvent.new
      event.charge_processor_id = charge_processor_id
      event.charge_event_id = stripe_event["id"]
      event.charge_id = stripe_dispute["charge"]
      event.created_at = DateTime.strptime(stripe_event["created"].to_s, "%s")
      event.comment = stripe_event["type"]
      event.extras = {
        charge_processor_dispute_id: stripe_dispute["id"],
        reason: stripe_dispute["reason"].presence
      }

      stripe_charge = if stripe_connect_account_id.present? && stripe_connect_account_id != Stripe::Account.retrieve.id
        Stripe::Charge.retrieve(
          { id: event.charge_id,
            expand: %w[balance_transaction transfer.reversals.data.balance_transaction application_fee.refunds.data.balance_transaction] },
          { stripe_account: stripe_connect_account_id }
        )
      else
        Stripe::Charge.retrieve(
          id: event.charge_id,
          expand: %w[balance_transaction transfer.reversals.data.balance_transaction application_fee.refunds.data.balance_transaction]
        )
      end

      event.charge_reference = get_charge_reference(stripe_charge)

      if stripe_charge.destination
        case stripe_event["type"]
        when "charge.dispute.funds_withdrawn"
          handle_stripe_event_charge_dispute_for_charge_with_destination_funds_widthdrawn(stripe_dispute, stripe_charge, event)
        when "charge.dispute.funds_reinstated"
          handle_stripe_event_charge_dispute_for_charge_with_destination_funds_reinstated(stripe_dispute, stripe_charge, event)
        when "charge.dispute.closed"
          event.type = stripe_dispute.status == "lost" ? ChargeEvent::TYPE_DISPUTE_LOST : ChargeEvent::TYPE_INFORMATIONAL
        else
          event.type = ChargeEvent::TYPE_INFORMATIONAL
        end
      else
        case stripe_event["type"]
        when "charge.dispute.created"
          event.type = ChargeEvent::TYPE_DISPUTE_FORMALIZED
          event.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(stripe_dispute.currency, -1 * stripe_dispute.amount)
        when "charge.dispute.closed"
          case stripe_dispute.status
          when "won", "warning_closed"
            event.type = ChargeEvent::TYPE_DISPUTE_WON
            event.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(stripe_dispute.currency, stripe_dispute.amount)
          when "lost"
            event.type = ChargeEvent::TYPE_DISPUTE_LOST
          end
        else
          event.type = ChargeEvent::TYPE_INFORMATIONAL
        end
      end
    elsif stripe_event["type"] == "charge.refund.updated"
      event = ChargeEvent.new
      event.charge_processor_id = charge_processor_id
      event.charge_event_id = stripe_event["id"]
      event.charge_id = stripe_event["data"]["object"]["charge"]
      event.refund_id = stripe_event["data"]["object"]["id"]
      event.processor_payment_intent_id = stripe_event["data"]["object"]["payment_intent"]
      event.created_at = DateTime.strptime(stripe_event["created"].to_s, "%s")
      event.comment = stripe_event["type"]
      event.extras = {
        refund_status: stripe_event["data"]["object"]["status"],
        refunded_amount_cents: stripe_event["data"]["object"]["amount"],
        refund_reason: stripe_event["data"]["object"]["reason"],
      }
      event.type = ChargeEvent::TYPE_CHARGE_REFUND_UPDATED
    elsif stripe_event["type"].start_with?("charge.")
      raise "Stripe Event #{stripe_event['id']} does not contain a 'charge' object." if stripe_event["data"]["object"]["object"] != "charge"

      # Charge events that have the twitter_username field set have been created on stripe by Twitter, and we do not
      # know about the purchase when the initial success event (charge.succeeded) is communicated to us about them.
      # Ignore them because of this. Note: We will receive a charge.captured event when the charge is captured and
      # we will know about the purchase at that point.
      return if stripe_event["type"] == "charge.succeeded" && stripe_event["data"]["object"]["metadata"]["twitter_username"].present?

      raise "Stripe Event #{stripe_event['id']} has no charge id." if stripe_event["data"]["object"]["id"].nil?
      raise "Stripe Event #{stripe_event['id']} has no created date." if stripe_event["created"].nil?

      event = ChargeEvent.new
      event.charge_processor_id = charge_processor_id
      event.charge_event_id = stripe_event["id"]
      event.charge_id = stripe_event["data"]["object"]["id"]
      event.processor_payment_intent_id = stripe_event["data"]["object"]["payment_intent"]
      event.charge_reference = get_charge_reference(stripe_event["data"]["object"])
      event.created_at = DateTime.strptime(stripe_event["created"].to_s, "%s")
      event.comment = stripe_event["type"]
      # Recurring charges on Indian cards go into processing state for 26 hours as per RBI guidelines.
      # We keep the corresponding purchase in progress on our end for that duration, and transition it
      # to success/fail when we receive the respective webhook.
      event.type = if stripe_event["type"] == "charge.succeeded"
        ChargeEvent::TYPE_CHARGE_SUCCEEDED
      else
        ChargeEvent::TYPE_INFORMATIONAL
      end
    elsif stripe_event["type"].starts_with?("payment_intent.payment_failed")
      raise "Stripe Event #{stripe_event['id']} does not contain a 'payment_intent' object." if stripe_event["data"]["object"]["object"] != "payment_intent"

      event = ChargeEvent.new
      event.charge_processor_id = charge_processor_id
      event.charge_event_id = stripe_event["id"]
      event.processor_payment_intent_id = stripe_event["data"]["object"]["id"]
      event.charge_reference = get_charge_reference(stripe_event["data"]["object"])
      event.created_at = DateTime.strptime(stripe_event["created"].to_s, "%s")
      event.comment = stripe_event["type"]
      event.type = ChargeEvent::TYPE_PAYMENT_INTENT_FAILED
    end

    ChargeProcessor.handle_event(event) unless event.nil?
  end

  def self.handle_stripe_event_charge_dispute_for_charge_with_destination_funds_widthdrawn(stripe_dispute, stripe_charge, event)
    event.type = ChargeEvent::TYPE_DISPUTE_FORMALIZED
    stripe_transfer_reversals = stripe_charge.transfer.reversals
    stripe_transfer_reversals.create(refund_application_fee: true) if stripe_transfer_reversals.data.empty?
    stripe_charge.refresh
    issued_amount = FlowOfFunds::Amount.new(
      currency: stripe_dispute.currency,
      cents: -1 * stripe_dispute.amount
    )
    chargeback_withdrawal_balance_transaction = stripe_dispute.balance_transactions.find do |balance_transaction|
      balance_transaction.description[/^Chargeback withdrawal/].present?
    end
    settled_amount = FlowOfFunds::Amount.new(
      currency: chargeback_withdrawal_balance_transaction.currency,
      cents: chargeback_withdrawal_balance_transaction.amount
    )
    destination_transfer = Stripe::Transfer.retrieve(id: stripe_charge.transfer.id)
    stripe_destination_payment = Stripe::Charge.retrieve({ id: destination_transfer.destination_payment,
                                                           expand: %w[refunds.data.balance_transaction application_fee.refunds] },
                                                         { stripe_account: destination_transfer.destination })

    if stripe_charge.application_fee.present?
      # For old charges with `application_fee_amount` parameter, we get the gumroad amount from the
      # application_fee object attached to the charge.
      gumroad_amount_currency = stripe_charge.application_fee.refunds.first.balance_transaction.currency
      gumroad_amount_cents = stripe_charge.application_fee.refunds.first.balance_transaction.amount
    else
      # For new charges with `transfer_data[amount]` parameter instead of `application_fee_amoount`, there's
      # no application_fee object attached to the charge so we calculate the gumroad amount as difference between
      # the total charge amount and the amount transferred to the connect account.
      gumroad_amount_currency = stripe_charge.currency
      gumroad_amount_cents = -1 * (stripe_charge.amount - destination_transfer.amount)
    end
    gumroad_amount = FlowOfFunds::Amount.new(currency: gumroad_amount_currency, cents: gumroad_amount_cents)

    merchant_account_gross_amount = FlowOfFunds::Amount.new(
      currency: stripe_destination_payment.refunds.first.balance_transaction.currency,
      cents: stripe_destination_payment.refunds.first.balance_transaction.amount
    )
    merchant_account_net_amount = FlowOfFunds::Amount.new(
      currency: stripe_destination_payment.refunds.first.balance_transaction.currency,
      cents: stripe_destination_payment.application_fee.present? ?
               stripe_destination_payment.refunds.first.balance_transaction.amount + stripe_destination_payment.application_fee.refunds.first.amount :
               stripe_destination_payment.refunds.first.balance_transaction.net
    )
    event.flow_of_funds = FlowOfFunds.new(
      issued_amount:,
      settled_amount:,
      gumroad_amount:,
      merchant_account_gross_amount:,
      merchant_account_net_amount:
    )
  end

  def self.handle_stripe_event_charge_dispute_for_charge_with_destination_funds_reinstated(stripe_dispute, stripe_charge, event)
    event.type = ChargeEvent::TYPE_DISPUTE_WON
    # NOTE: The application fee billed is the same application fee that was refunded to us when the chargeback occurred.
    # If for some reason the chargeback reversal returned to us a different amount than was originally chargedback (e.g. due to currency changes)
    # we will still bill them the same amount we were refunded originally.

    # Fetch the purchase for the chargeback. We want to always refund the user in USD
    # There is no such information available in USD for us on non-USD purchases
    # or Stripe Accounts with a different currency. Instead we just reverse and transfer back payment_cents
    # which are in USD amount.

    chargeable = Charge::Chargeable.find_by_processor_transaction_id!(stripe_charge.id)
    amount_cents = chargeable.charged_amount_cents - chargeable.charged_gumroad_amount_cents

    stripe_transfer = StripeTransferInternallyToCreator.transfer_funds_to_account(
      message_why: "Dispute #{stripe_dispute.id} won",
      stripe_account_id: stripe_charge.destination,
      currency: Currency::USD,
      # Transfer Amount- Fees to Creator account. In future, we won't need to do this as we would have not sent fees at all before
      amount_cents:,
      related_charge_id: stripe_charge.id
    )
    issued_amount = FlowOfFunds::Amount.new(
      currency: stripe_dispute.currency,
      cents: stripe_dispute.amount
    )
    chargeback_reversal_balance_transaction = stripe_dispute.balance_transactions.find do |balance_transaction|
      balance_transaction.description[/^Chargeback reversal/].present?
    end
    settled_amount = FlowOfFunds::Amount.new(
      currency: chargeback_reversal_balance_transaction.currency,
      cents: chargeback_reversal_balance_transaction.amount
    )

    destination_payment = Stripe::Charge.retrieve(
      {
        id: stripe_transfer.destination_payment,
        expand: %w[balance_transaction]
      },
      { stripe_account: stripe_transfer.destination }
    )

    gumroad_amount = stripe_charge.application_fee.present? ?
                       FlowOfFunds::Amount.new(
                         currency: stripe_charge.application_fee.currency,
                         cents: stripe_charge.application_fee.amount_refunded) :
                       FlowOfFunds::Amount.new(
                         currency: stripe_charge.currency,
                         cents: stripe_charge.amount - amount_cents)

    merchant_account_gross_amount = FlowOfFunds::Amount.new(
      currency: destination_payment.balance_transaction.currency,
      cents: destination_payment.balance_transaction.amount
    )
    merchant_account_net_amount = FlowOfFunds::Amount.new(
      currency: destination_payment.balance_transaction.currency,
      cents: destination_payment.balance_transaction.net
    )
    event.flow_of_funds = FlowOfFunds.new(
      issued_amount:,
      settled_amount:,
      gumroad_amount:,
      merchant_account_gross_amount:,
      merchant_account_net_amount:
    )
  end

  def transaction_url(charge_id)
    Rails.env.production? ? "https://manage.stripe.com/payments/#{charge_id}" : "https://manage.stripe.com/test/payments/#{charge_id}"
  end

  def self.fingerprint_search_url(fingerprint)
    Rails.env.production? ? "https://manage.stripe.com/search?query=fingerprint:#{fingerprint}" : "https://manage.stripe.com/test/search?query=fingerprint:#{fingerprint}"
  end

  private_class_method
  def self.calculate_transfer_reversal(transfer, data)
    return unless transfer.present?

    transfer_amount_available_to_reverse = transfer.amount - transfer.amount_reversed
    return unless transfer_amount_available_to_reverse > 0

    transfer_currency = transfer.currency.to_sym
    return unless data.key?(transfer_currency)

    amount_left = data[transfer_currency][:owed] - data[transfer_currency][:sum_of_transfer_amounts]
    amount_to_reverse = [transfer_amount_available_to_reverse, amount_left].min

    data[transfer_currency][:transfers] << [transfer.id, amount_to_reverse]

    data[transfer_currency][:sum_of_transfer_amounts] += amount_to_reverse
  end

  private
    # https://stripe.com/docs/api/files/object#file_object-purpose
    STRIPE_FILE_PURPOSE_DISPUTE_EVIDENCE = "dispute_evidence"

    def create_dispute_evidence_stripe_file(blob)
      return unless blob.attached?

      file = Tempfile.new(["#file", File.extname(blob.filename.to_s)], binmode: true)
      begin
        file.write(blob.download)
        file.rewind
        Stripe::File.create(file:, purpose: STRIPE_FILE_PURPOSE_DISPUTE_EVIDENCE).id
      ensure
        file.close!
      end
    end

    def get_mandate_id_from_chargeable(chargeable, merchant_account)
      if chargeable.stripe_setup_intent_id
        setup_intent = if merchant_migrated?(merchant_account)
          Stripe::SetupIntent.retrieve(chargeable.stripe_setup_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
        else
          Stripe::SetupIntent.retrieve(chargeable.stripe_setup_intent_id)
        end
        setup_intent.mandate
      elsif chargeable.stripe_payment_intent_id
        original_payment_intent = if merchant_migrated?(merchant_account)
          Stripe::PaymentIntent.retrieve(chargeable.stripe_payment_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
        else
          Stripe::PaymentIntent.retrieve(chargeable.stripe_payment_intent_id)
        end
        original_charge = if merchant_migrated?(merchant_account)
          Stripe::Charge.retrieve(original_payment_intent.latest_charge, { stripe_account: merchant_account.charge_processor_merchant_id })
        else
          Stripe::Charge.retrieve(original_payment_intent.latest_charge)
        end
        original_charge.payment_method_details.card.mandate
      end
    end

    def self.get_charge_reference(stripe_charge)
      if stripe_charge["transfer_group"].to_s.starts_with?(Charge::COMBINED_CHARGE_PREFIX)
        stripe_charge["transfer_group"]
      else
        stripe_charge["metadata"]["purchase"]
      end
    end
end
