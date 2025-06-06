# frozen_string_literal: true

module PayoutsHelper
  include CurrencyHelper
  # Payments before this date don't have balances associated with them (pre rolling payouts)
  OLDEST_DISPLAYABLE_PAYOUT_PERIOD_END_DATE = Date.parse("2013-01-04")

  def formatted_payout_date(payout_date)
    return "" if payout_date.nil?
    payout_date.strftime("%B #{payout_date.day.ordinalize}, %Y")
  end

  def payout_period_data(user, payment = nil)
    payout_period_data = {
      should_be_shown_currencies_always: user.should_be_shown_currencies_always?
    }
    if payment.nil?
      # Current payout period
      payout_period_data.merge(current_payout_period_data(user:))
    else
      payout_period_data.merge(old_payout_period_data(user:, payment:))
    end
  end

  def current_payout_end_date(user)
    next_payout_date = user.next_payout_date
    if user.payout_frequency == User::DAILY
      next_payout_date - 1
    else
      next_payout_date - User::PayoutSchedule::PAYOUT_DELAY_DAYS
    end
  end

  def current_payout_period_data(user:)
    payout_period_data = {}
    minimum_payout_amount_cents = user.minimum_payout_amount_cents
    payout_period_data[:minimum_payout_amount_cents] = minimum_payout_amount_cents
    payout_period_data[:is_user_payable] = user.unpaid_balance_cents >= payout_period_data[:minimum_payout_amount_cents]

    if payout_period_data[:is_user_payable]
      payout_period_data[:status] = user.payouts_status

      previous_payment = user.payments.completed_or_processing
                             .displayable
                             .order("created_at DESC")
                             .first

      payout_period_end_date = current_payout_end_date(user)

      payout_period_data[:displayable_payout_period_range] = displayable_payout_period_range(previous_payment, payout_period_end_date)
      payout_period_data[:payout_currency] = user.currency_type
      payout_period_data[:payout_cents] = user.unpaid_balance_cents_up_to_date(payout_period_end_date)
      payout_period_data[:payout_displayed_amount] = formatted_dollar_amount(payout_period_data[:payout_cents])
      payout_period_data[:payout_date_formatted] = formatted_payout_date(user.next_payout_date)
      payout_period_data[:type] = if user.payout_frequency == User::DAILY && Payouts.is_user_payable(user, payout_period_end_date, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
        Payouts::PAYOUT_TYPE_INSTANT
      else
        Payouts::PAYOUT_TYPE_STANDARD
      end

      balance_ids = user.unpaid_balances_up_to_date(payout_period_end_date).map(&:id)
      payout_period_data.merge!(payout_sales_data(user:, balance_ids:,
                                                  start_date: previous_payment&.payout_period_end_date.try(:next),
                                                  end_date: payout_period_end_date))

      payout_period_data.merge!(payout_method_details(user:))
    else
      payout_period_data[:status] = "not_payable"
    end

    last_payout_note = user.comments.with_type_payout_note.where(author_id: GUMROAD_ADMIN_ID).where.not("content like 'Payout via PayPal%'").last
    payout_period_data[:payout_note] = \
      if last_payout_note.present? && last_payout_note.created_at.to_i > user.payments.completed_or_processing.last&.created_at.to_i
        last_payout_note.content.gsub("via Stripe ", "")
      else
        nil
      end

    payout_period_data
  end

  def old_payout_period_data(user:, payment:)
    payout_period_data = {}
    previous_payment = user.payments.completed_or_processing
      .displayable
      .where("created_at <= ?", payment.created_at)
      .where("id < ?", payment.id)
      .order("created_at DESC")
      .first

    formatted_payout_period_end_date = formatted_payout_date(payment.payout_period_end_date)

    payout_period_data[:displayable_payout_period_range] = if previous_payment.present?
      if previous_payment.payout_period_end_date == payment.payout_period_end_date
        "Activity on #{formatted_payout_period_end_date}"
      else
        "Activity from #{formatted_payout_date(previous_payment.payout_period_end_date + 1)} to #{formatted_payout_period_end_date}"
      end
    else
      "Activity up to #{formatted_payout_period_end_date}"
    end

    payout_period_data[:payout_date_formatted] = formatted_payout_date(payment.created_at)
    payout_period_data[:payout_currency] = payment.currency
    payout_period_data[:payout_cents] = payment.amount_cents
    payout_period_data[:payout_displayed_amount] = payment.displayed_amount
    payout_period_data[:is_processing] = payment.processing?
    payout_period_data[:arrival_date] = payment.arrival_date ? formatted_payout_date(Time.zone.at(payment.arrival_date)) : nil
    payout_period_data[:status] = payment.state
    payout_period_data[:payment_external_id] = payment.external_id
    payout_period_data[:type] = payment.payout_type || Payouts::PAYOUT_TYPE_STANDARD

    payout_period_data[:payout_note] = nil

    balance_ids = payment.balances.map(&:id)
    payout_period_data.merge!(payout_sales_data(user:, balance_ids:,
                                                start_date: previous_payment&.payout_period_end_date.try(:next),
                                                end_date: payment.payout_period_end_date))

    if payment.gumroad_fee_cents.present?
      payout_period_data[:fees_cents] = payout_period_data[:fees_cents].to_i + payment.gumroad_fee_cents
    end

    payout_period_data.merge(payout_method_details(payment:))
  end

  def payout_sales_data(user:, balance_ids:, start_date:, end_date:)
    sales_data_from_balances = user.sales_data_for_balance_ids(balance_ids)
    paypal_sales_data = user.paypal_sales_data_for_duration(start_date:, end_date:)
    total_sales_data_for_payout = sales_data_from_balances.merge(paypal_sales_data) { |_key, value1, value2| value1 + value2 }
    paypal_payout_cents = user.paypal_payout_net_cents(paypal_sales_data)
    total_sales_data_for_payout[:paypal_payout_cents] = paypal_payout_cents
    stripe_connect_sales_data = user.stripe_connect_sales_data_for_duration(start_date:, end_date:)
    total_sales_data_for_payout = total_sales_data_for_payout.merge(stripe_connect_sales_data) { |_key, value1, value2| value1 + value2 }
    stripe_connect_payout_cents = user.stripe_connect_payout_net_cents(stripe_connect_sales_data)
    total_sales_data_for_payout.merge({ stripe_connect_payout_cents: })
  end

  def displayable_payout_period_range(previous_payment, payout_period_end_date)
    if previous_payment.present?
      activity_start_date = [previous_payment.payout_period_end_date + 1, Date.current].min
      if payout_period_end_date > Date.current
        "Activity since #{formatted_payout_date(activity_start_date)}"
      elsif payout_period_end_date == activity_start_date
        "Activity on #{formatted_payout_date(payout_period_end_date)}"
      else
        "Activity from #{formatted_payout_date([previous_payment.payout_period_end_date + 1, Date.current].min)} to #{formatted_payout_date(payout_period_end_date)}"
      end
    else
      if payout_period_end_date > Date.current
        "Activity up to now"
      else
        "Activity up to #{formatted_payout_date(payout_period_end_date)}"
      end
    end
  end

  def payout_method_details(user: nil, payment: nil)
    return {} if user.blank? && payment.blank?

    bank_account = payment.present? ? payment.bank_account : user.active_bank_account
    stripe_connect_account_id = nil

    if payment.present?
      merchant_account = payment.user.merchant_accounts.find_by(charge_processor_merchant_id: payment.stripe_connect_account_id)
      stripe_connect_account_id = payment.stripe_connect_account_id if merchant_account&.is_a_stripe_connect_account?
    else
      balances = user.unpaid_balances_up_to_date(current_payout_end_date(user))
      merchant_account, _, _ = StripePayoutProcessor.get_payout_details(user, balances)
      stripe_connect_account_id = merchant_account.charge_processor_merchant_id if merchant_account&.is_a_stripe_connect_account?
    end

    if stripe_connect_account_id
      { payout_method_type: "stripe_connect", stripe_connect_account_id: }
    elsif bank_account.present?
      bank_account.to_hash.merge(payout_method_type: "bank")
    else
      paypal_address = payment.present? ? payment.payment_address : user.paypal_payout_email
      if paypal_address.present?
        { payout_method_type: "paypal", paypal_address: }
      else
        if payment.present?
          { payout_method_type: "legacy-na" }
        else
          { payout_method_type: "none" }
        end
      end
    end
  end
end
