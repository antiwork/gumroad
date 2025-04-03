# frozen_string_literal: true

class StripePayoutProcessor
  extend CurrencyHelper

  DEBIT_CARD_PAYOUT_MAX = 300_000
  INSTANT_PAYOUT_FEE_PERCENT = 3

  # Public: Determines if it's possible for this processor to payout
  # the user by checking that the user has provided us with the
  # information we need to be able to payout with this processor.
  #
  # This payout processor can payout any user who has a Stripe managed account
  # and has a bank account setup.
  def self.is_user_payable(user, amount_payable_usd_cents, add_comment: false, from_admin: false)
    payout_date = Time.current.to_fs(:formatted_date_full_month)

    # If a user's previous payment is still processing, don't allow for new payments.
    processing_payment_ids = user.payments.processing.ids
    if processing_payment_ids.any?
      user.add_payout_note(content: "Payout on #{payout_date} was skipped because there was already a payout in processing.") if add_comment
      return false
    end

    # Return true if user has a Stripe account connected
    return true if user.has_stripe_account_connected? && !user.stripe_connect_account.is_a_brazilian_stripe_connect_account?

    # Don't payout users who don't have a bank account
    if user.active_bank_account.nil?
      user.add_payout_note(content: "Payout on #{payout_date} was skipped because a bank account wasn't added at the time.") if add_comment
      return false
    end

    # Don't payout users whose bank account is not linked to a bank account at Stripe
    if user.active_bank_account.stripe_bank_account_id.blank? || user.stripe_account.nil?
      user.add_payout_note(content: "Payout on #{payout_date} was skipped because the payout bank account was not correctly set up.") if add_comment
      return false
    end
    true
  end

  def self.has_valid_payout_info?(user)
    # Return true if user has a Stripe account connected
    return true if user.has_stripe_account_connected?
    # Don't payout users who don't have a bank account
    return false if user.active_bank_account.nil?
    # Don't payout users whose bank account is not linked to a bank account at Stripe
    return false if user.active_bank_account.stripe_bank_account_id.blank?
    # Don't payout users who don't have an active Stripe merchant account
    return false if user.stripe_account.nil?

    true
  end

  # Public: Determines if the processor can payout the balance. Since
  # balances can be being held either by Gumroad or by specific processors
  # a balance may not be payable by a processor if the balance is not
  # being held by Gumroad.
  #
  # This payout processor can payout any balance that's held by Stripe,
  # where the purchase was charged on a creator's own Stripe account.
  def self.is_balance_payable(balance)
    case balance.merchant_account.holder_of_funds
    when HolderOfFunds::STRIPE
      balance.holding_currency == balance.merchant_account.currency
    when HolderOfFunds::GUMROAD
      true
    else
      false
    end
  end

  # Public: Get the payout destination and categorized balances for a user
  def self.get_payout_details(user, balances)
    balances_by_holder_of_funds = balances.group_by { |balance| balance.merchant_account.holder_of_funds }
    balances_held_by_gumroad = balances_by_holder_of_funds[HolderOfFunds::GUMROAD] || []
    balances_held_by_stripe = balances_by_holder_of_funds[HolderOfFunds::STRIPE] || []

    # If user has a Stripe standard account connected and there are no balances_held_by_stripe, we issue payout to the
    # connected Stripe standard account.
    #
    # If there is no Stripe Connect account or if there is balances_held_by_stripe,
    # that means the custom Stripe connect account (which is managed by gumroad) is still in use and there's some amount
    # in the custom Stripe connect account that needs to be paid out.
    # We issue payout via the custom Stripe connect account in that case.
    #
    # Once a standard Stripe account is connected, balances_held_by_stripe will eventually come down to zero as
    # new sales will go directly to the connected Stripe account and no new balance will be generated
    # against the custom Stripe connect account.
    merchant_account = if user.has_stripe_account_connected? && balances_held_by_stripe.blank?
      user.stripe_connect_account
    else
      user.stripe_account || balances_held_by_stripe[0]&.merchant_account
    end

    return merchant_account, balances_held_by_gumroad, balances_held_by_stripe
  end

  def self.instantly_payable_amount_cents_on_stripe(user)
    active_bank_account = user.active_bank_account
    return 0 if active_bank_account.blank?


    balance = Stripe::Balance.retrieve(
      { expand: ["instant_available.net_available"] },
      { stripe_account: active_bank_account.stripe_connect_account_id }
    )

    balance.try(:instant_available)
      &.first
      &.try(:net_available)
      &.find { _1["destination"] == active_bank_account.stripe_bank_account_id }
      &.[]("amount") || 0
  end

  # Public: Takes the actions required to prepare the payment, that include:
  #   * Setting the currency.
  #   * Setting the amount_cents.
  # Returns an array of errors.
  def self.prepare_payment_and_set_amount(payment, balances)
    merchant_account, balances_held_by_gumroad, balances_held_by_stripe = get_payout_details(payment.user, balances)
    payment.stripe_connect_account_id = merchant_account.charge_processor_merchant_id
    payment.currency = merchant_account.currency
    payment.amount_cents = 0

    payment.amount_cents += balances_held_by_stripe.sum(&:holding_amount_cents)

    # If the user is being paid out funds held by Gumroad, transfer those funds to the creators Stripe account.
    amount_cents_held_by_gumroad = balances_held_by_gumroad.sum(&:holding_amount_cents)
    if amount_cents_held_by_gumroad > 0
      internal_transfer = StripeTransferInternallyToCreator.transfer_funds_to_account(
        message_why: "Funds held by Gumroad for Payment #{payment.external_id}.",
        stripe_account_id: payment.stripe_connect_account_id,
        currency: Currency::USD,
        amount_cents: amount_cents_held_by_gumroad,
        metadata: {
          payment: payment.external_id
        }.merge(StripeMetadata.build_metadata_large_list(balances_held_by_gumroad.map(&:external_id),
                                                         key: :balances,
                                                         separator: ",",
                                                         # 1 key (`payment`) already added above so allow max - 1 more keys
                                                         max_key_length: StripeMetadata::STRIPE_METADATA_MAX_KEYS_LENGTH - 1))
      )
      destination_payment = Stripe::Charge.retrieve(
        {
          id: internal_transfer.destination_payment,
          expand: %w[balance_transaction]
        },
        { stripe_account: payment.stripe_connect_account_id }
      )
      payment.amount_cents += destination_payment.balance_transaction.amount
      payment.stripe_internal_transfer_id = internal_transfer.id
    end
    # For HUF and TWD, Stripe only supports payout amount cents that are divisible by 100 (Ref: https://stripe.com/docs/currencies#special-cases)
    # So we discard the mod hundred amount when making the payout, but mark the entire amount as paid on our end.
    payment.amount_cents -= payment.amount_cents % 100 if [Currency::HUF, Currency::TWD].include?(payment.currency)

    # Our currencies.yml assumes KRW to have 100 subunits, and that's how we store them in the database.
    # However, Stripe treats KRW as a single-unit currency. So we convert the value here.
    payment.amount_cents = payment.amount_cents * 100 if payment.currency == Currency::KRW

    # For instant payouts, the amount has to be net of instant payout fees.
    if payment.payout_type == Payouts::PAYOUT_TYPE_INSTANT
      payment.amount_cents = (payment.amount_cents * 100.0 / (100 + INSTANT_PAYOUT_FEE_PERCENT)).floor
    end

    []
  rescue Stripe::InvalidRequestError => e
    failed = true
    Bugsnag.notify(e)
    [e.message]
  rescue Stripe::AuthenticationError, Stripe::APIConnectionError
    failed = true
    raise
  rescue Stripe::StripeError => e
    failed = true
    Bugsnag.notify(e)
    [e.message]
  ensure
    payment.mark_failed! if failed
  end

  def self.enqueue_payments(user_ids, date_string)
    user_ids.each do |user_id|
      PayoutUsersWorker.perform_async(date_string, PayoutProcessorType::STRIPE, user_id)
    end
  end

  def self.process_payments(payments)
    payments.each do |payment|
      perform_payment(payment)
    end
  end

  # Public: Actually sends the money.
  # Returns an array of errors.
  def self.perform_payment(payment)
    # We have transferred the balance held by gumroad to the connected Stripe standard account.
    # No payout needs to be issued in this case.
    merchant_account = payment.user.merchant_accounts.find_by(charge_processor_merchant_id: payment.stripe_connect_account_id)
    if merchant_account.is_a_stripe_connect_account?
      stripe_transfer = Stripe::Transfer.retrieve(payment.stripe_internal_transfer_id)
      payment.stripe_transfer_id = stripe_transfer.destination_payment
      payment.mark_completed!
      return
    end

    amount_cents = if payment.currency == Currency::KRW
      # Our currencies.yml assumes KRW to have 100 subunits, and that's how we store them in the database.
      # However, Stripe treats KRW as a single-unit currency. So we convert the value here.
      payment.amount_cents / 100
    else
      payment.amount_cents
    end

    # Transfer the payout amount from the creators Stripe account to their bank account.
    params = {
      amount: amount_cents,
      currency: payment.currency,
      destination: payment.bank_account.stripe_external_account_id,
      statement_descriptor: "Gumroad",
      description: payment.external_id,
      metadata: {
        payment: payment.external_id,
        bank_account: payment.bank_account.external_id
      }.merge(StripeMetadata.build_metadata_large_list(payment.balances.map(&:external_id),
                                                       key: :balances,
                                                       separator: ",",
                                                       # 2 keys (`payment` and `bank_account`) already added above so allow max - 2 more keys
                                                       max_key_length: StripeMetadata::STRIPE_METADATA_MAX_KEYS_LENGTH - 2))
    }
    params.merge!(method: payment.payout_type) if payment.payout_type.present?
    stripe_payout = Stripe::Payout.create(params, { stripe_account: payment.stripe_connect_account_id })
    payment.stripe_transfer_id = stripe_payout.id
    payment.arrival_date = stripe_payout.arrival_date
    payment.gumroad_fee_cents = stripe_payout.application_fee_amount if payment.payout_type == Payouts::PAYOUT_TYPE_INSTANT
    payment.save!
    []
  rescue Stripe::InvalidRequestError => e
    failed = true
    if e.message["Cannot create live transfers"]
      failure_reason = Payment::FailureReason::CANNOT_PAY
    elsif e.message["Debit card transfers are only supported for amounts less"]
      failure_reason = Payment::FailureReason::DEBIT_CARD_LIMIT
    elsif e.message["Insufficient funds in Stripe account"]
      failure_reason = Payment::FailureReason::INSUFFICIENT_FUNDS
    else
      Bugsnag.notify(e)
    end
    Rails.logger.info("Payouts: Payout errors for user with id: #{payment.user_id} #{e.message}")
    [e.message]
  rescue Stripe::AuthenticationError, Stripe::APIConnectionError
    failed = true
    raise
  rescue Stripe::StripeError => e
    failed = true
    Bugsnag.notify(e)
    Rails.logger.info("Payouts: Payout errors for user with id: #{payment.user_id} #{e.message}")
    [e.message]
  ensure
    Rails.logger.info("Payouts: Payout of #{payment.amount_cents} attempted for user with id: #{payment.user_id}")
    if failed
      payment.mark_failed!(failure_reason)
      reverse_internal_transfer!(payment)
    end
  end

  def self.handle_stripe_event(stripe_event, stripe_connect_account_id:)
    stripe_event_id = stripe_event["id"]
    stripe_event_type = stripe_event["type"]

    return unless stripe_event_type.in?(%w[
                                          payout.paid
                                          payout.canceled
                                          payout.failed
                                        ])

    # Get the Stripe Payout object
    event_object = stripe_event["data"]["object"]
    raise "Stripe Event #{stripe_event_id}: does not contain a payout object." if event_object["object"] != "payout"

    is_payout_reversal = event_object["original_payout"].present?

    stripe_payout_id = is_payout_reversal ? event_object["original_payout"] : event_object["id"]
    raise "Stripe Event #{stripe_event_id}: payout has no payout id." if stripe_payout_id.blank?

    stripe_payout = Stripe::Payout.retrieve(stripe_payout_id, { stripe_account: stripe_connect_account_id })

    merchant_account = MerchantAccount.find_by(charge_processor_merchant_id: stripe_connect_account_id)
    return if merchant_account.blank? || merchant_account.is_a_stripe_connect_account? || merchant_account.currency != stripe_payout["currency"]

    if stripe_payout["automatic"]
      if stripe_payout["amount"] >= 0
        # Ignore events about automatic on-schedule payouts (not triggered by Gumroad). Ref: https://github.com/gumroad/web/issues/16938
        Rails.logger.info("Ignoring automatic payout event #{stripe_event_id} for stripe account #{stripe_connect_account_id}")
      else
        case stripe_event_type
        when "payout.paid"
          # Wait 7 calendar days before checking the payout's status because state changes within next 5 business
          # days aren't final: https://stripe.com/docs/api/payouts/object#payout_object-status
          HandleStripeAutodebitForNegativeBalance.perform_in(7.days, stripe_event_id, stripe_connect_account_id, stripe_payout_id)
        end
        # We don't need to handle payout.canceled or payout.failed because we don't need to credit to gumroad account when stripe balance didnt change.
      end
      return
    end

    # We lookup the payment on master to ensure we're looking at the latest version and have the latest state.
    ActiveRecord::Base.connection.stick_to_primary!
    # Find the matching Payment
    payment = Payment
              .processed_by(PayoutProcessorType::STRIPE)
              .find_by(stripe_connect_account_id:, stripe_transfer_id: stripe_payout_id)
    raise "Stripe Event #{stripe_event_id}: payout does not match any payment." if payment.nil?
    raise "Stripe Event #{stripe_event_id}: payout mismatches on payment ID." if payment.external_id != stripe_payout["metadata"]["payment"]

    if is_payout_reversal
      reversing_payout_id = event_object["id"]

      case stripe_event_type
      when "payout.paid"
        # Wait 7 calendar days before checking the reversing payout's status because state changes within next 5 business
        # days aren't final: https://stripe.com/docs/api/payouts/object#payout_object-status
        # https://github.com/gumroad/web/pull/23719
        HandlePayoutReversedWorker.perform_in(7.days, payment.id, reversing_payout_id, stripe_connect_account_id)
      when "payout.failed"
        handle_stripe_event_payout_reversal_failed(payment, reversing_payout_id)
      end
    else
      case stripe_event_type
      when "payout.paid"
        handle_stripe_event_payout_paid(payment, stripe_payout)
      when "payout.canceled"
        handle_stripe_event_payout_cancelled(payment)
      when "payout.failed"
        handle_stripe_event_payout_failed(payment, failure_reason: stripe_payout["failure_code"])
      end
    end
  end

  def self.handle_stripe_negative_balance_debit_event(stripe_connect_account_id, stripe_payout_id)
    # This is a stripe automatic debit made by stripe due to negative balance in user stripe account
    stripe_payout = Stripe::Payout.retrieve(stripe_payout_id, { stripe_account: stripe_connect_account_id })
    amount_cents = stripe_payout["amount"]
    merchant_account = MerchantAccount.find_by(charge_processor_merchant_id: stripe_connect_account_id)
    return unless amount_cents < 0

    Credit.create_for_bank_debit_on_stripe_account!(amount_cents: amount_cents.abs, merchant_account:)
  end

  def self.handle_stripe_event_payout_reversed(payment, reversing_payout_id)
    payment.with_lock do
      case payment.state
      when "processing"
        payment.mark_failed!
      when "completed"
        payment.mark_returned!
      else
        return
      end

      reverse_internal_transfer!(payment)

      payment.processor_reversing_payout_id = reversing_payout_id
      payment.save!
    end
  end

  def self.handle_stripe_event_payout_reversal_failed(payment, reversing_payout_id)
    # Normally, when someone initiates a reversal of the payout from Stripe dashboard and it fails -
    # there's nothing for us to do.
    #
    # However, as per Stripe docs: "Some failed payouts may initially show as paid but then change to failed"
    # (https://stripe.com/docs/api/payouts/object#payout_object-status). So if this reversal was initially reported
    # as `paid` (and we marked linked balances as `unpaid`), but has now changed to `failed`, we might have
    # attempted to re-pay those balances in the meanwhile. We may also have to re-do the previously reversed internal
    # transfer.
    #
    # We wait for the reversal transfer to be finalized before marking linked balances as `unpaid`,
    # so we should never have to raise here. If we did - there's a bug in the code.
    if payment.reversed_by?(reversing_payout_id)
      raise "Payout #{payment.id} was reversed in Stripe console, the reversal was reported as paid, "\
                            "we marked the payout as returned and may have since re-paid linked balances to the creator. "\
                            "Stripe has now notified us that the original reversal has failed. The case needs manual review."
    end
  end

  def self.handle_stripe_event_payout_paid(payment, stripe_payout)
    payment.with_lock do
      return unless payment.state == "processing"

      payment.arrival_date = stripe_payout["arrival_date"]
      payment.mark_completed!
    end
  end

  def self.handle_stripe_event_payout_cancelled(payment)
    payment.with_lock do
      raise "Expected payment #{payment.id} to be in processing state, got: #{payment.state}" unless payment.state == "processing"

      payment.mark_cancelled!
      reverse_internal_transfer!(payment)
    end
  end

  def self.handle_stripe_event_payout_failed(payment, failure_reason: nil)
    payment.with_lock do
      case payment.state
      when "processing"
        payment.mark_failed!
      when "completed"
        payment.mark_returned!
      else
        return
      end
    end

    reverse_internal_transfer!(payment)
    if failure_reason
      payment.failure_reason = failure_reason
      payment.save!
      payment.send_payout_failure_email
    end
  end

  def self.reverse_internal_transfer!(payment)
    return if payment.stripe_internal_transfer_id.nil?

    internal_transfer = Stripe::Transfer.retrieve(payment.stripe_internal_transfer_id)
    internal_transfer.reversals.create

    create_credit_for_difference_from_reversed_internal_transfer(payment, internal_transfer)
  end

  def self.create_credit_for_difference_from_reversed_internal_transfer(payment, internal_transfer)
    destination_payment = Stripe::Charge.retrieve(
      {
        id: internal_transfer.destination_payment,
        expand: %w[balance_transaction refunds]
      },
      { stripe_account: internal_transfer.destination }
    )
    refund_balance_transaction = Stripe::BalanceTransaction.retrieve(
      { id: destination_payment.refunds.first.balance_transaction }, { stripe_account: internal_transfer.destination }
    )

    difference_amount_cents = destination_payment.balance_transaction.net + refund_balance_transaction.net
    return if difference_amount_cents == 0

    merchant_account = MerchantAccount.where(
      user: payment.user,
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      charge_processor_merchant_id: internal_transfer.destination
    ).first
    Credit.create_for_returned_payment_difference!(
      user: payment.user,
      merchant_account:,
      returned_payment: payment,
      difference_amount_cents:
    )
  end
end
