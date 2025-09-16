# frozen_string_literal: true

class Payouts
  extend ActionView::Helpers::NumberHelper

  MIN_AMOUNT_CENTS = 10_00
  PAYOUT_TYPE_STANDARD = "standard"
  PAYOUT_TYPE_INSTANT = "instant"

  def self.is_user_payable(user, date, processor_type: nil, add_comment: false, from_admin: false, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    payout_date = Time.current.to_fs(:formatted_date_full_month)

    unless user.compliant? || from_admin
      user.add_payout_note(content: "Payout on #{payout_date} was skipped because the account was not compliant.") if add_comment
      return false
    end

    if user.payouts_paused?
      payouts_paused_by = user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE ? "payout processor" : user.payouts_paused_by_source
      user.add_payout_note(content: "Payout on #{payout_date} was skipped because payouts on the account were paused by the #{payouts_paused_by}.") if add_comment
      return false
    end

    amount_payable = user.unpaid_balance_cents_up_to_date(date)

    account_balance = amount_payable + user.paid_payments_cents_for_date(date)
    if account_balance < user.minimum_payout_amount_cents
      if add_comment && account_balance > 0
        current_balance = user.formatted_dollar_amount(account_balance, with_currency: true)
        minimum_balance = user.formatted_dollar_amount(user.minimum_payout_amount_cents, with_currency: true)
        user.add_payout_note(content: "Payout on #{payout_date} was skipped because the account balance #{current_balance} was less than the minimum payout amount of #{minimum_balance}.") if add_comment
      end
      is_payable_from_admin = from_admin && account_balance > 0 && user.unpaid_balance_cents_up_to_date_held_by_gumroad(date) == account_balance
      return false unless is_payable_from_admin
    end

    if payout_type == Payouts::PAYOUT_TYPE_INSTANT
      if !user.instant_payouts_supported?
        user.add_payout_note(content: "Payout on #{payout_date} was skipped because the account is not eligible for instant payouts.") if add_comment
        return false
      end

      amount_payable = user.instantly_payable_unpaid_balance_cents_up_to_date(date)
    end

    processor_types = processor_type ? [processor_type] : ::PayoutProcessorType.all
    processor_types.any? do |payout_processor_type|
      ::PayoutProcessorType.get(payout_processor_type).is_user_payable(user, amount_payable, add_comment:, from_admin:, payout_type:)
    end
  end

  def self.create_payments_for_balances_up_to_date(date, processor_type)
    users = User.holding_balance

    if processor_type == PayoutProcessorType::STRIPE
      users = users.joins(:merchant_accounts)
                   .where("merchant_accounts.deleted_at IS NULL")
                   .where("merchant_accounts.charge_processor_id = ?", StripeChargeProcessor.charge_processor_id)
                   .where("merchant_accounts.json_data->'$.meta.stripe_connect' = 'true'")
    end

    self.create_payments_for_balances_up_to_date_for_users(date, processor_type, users, perform_async: true)
  end

  def self.create_payments_for_balances_up_to_date_for_bank_account_types(date, processor_type, bank_account_types)
    bank_account_types.each do |bank_account_type|
      users = User.holding_balance
                  .joins("inner join bank_accounts on bank_accounts.user_id = users.id")
                  .where("bank_accounts.type = ?", bank_account_type)
                  .where("bank_accounts.deleted_at is null")
      self.create_payments_for_balances_up_to_date_for_users(date, processor_type, users, perform_async: true, bank_account_type:)
    end
  end

  def self.create_instant_payouts_for_balances_up_to_date(date)
    users = User.holding_balance.where("json_data->'$.payout_frequency' = 'daily'")
    self.create_instant_payouts_for_balances_up_to_date_for_users(date, users, perform_async: true, add_comment: true)
  end

  def self.create_payments_for_balances_up_to_date_for_users(date, processor_type, users, perform_async: false, retrying: false, bank_account_type: nil, from_admin: false)
    raise ArgumentError.new("Cannot payout for today or future balances.") if date >= Date.current

    user_ids_to_pay = []

    users.each do |user|
      if self.is_user_payable(
        user, date,
        processor_type:,
        add_comment: true,
        from_admin:
      ) &&
      (
        from_admin ||
        (
          user.next_payout_date.present? &&
          date + User::PayoutSchedule::PAYOUT_DELAY_DAYS >= user.next_payout_date
        )
      )
        user_ids_to_pay << user.id
        Rails.logger.info("Payouts: Payable user: #{user.id}")
      else
        Rails.logger.info("Payouts: Not payable user: #{user.id}")
      end
    end

    date_string = date.to_s
    if perform_async
      payout_processor = ::PayoutProcessorType.get(processor_type)
      payout_processor.enqueue_payments(user_ids_to_pay, date_string)
    else
      payments = []
      user_ids_to_pay.each do |user_id|
        payments << PayoutUsersService.new(date_string:,
                                           processor_type:,
                                           user_ids: user_id).process
      end
      payments.compact
    end
  end

  def self.create_instant_payouts_for_balances_up_to_date_for_users(date, users, perform_async: false, from_admin: false, add_comment: false)
    raise ArgumentError.new("Cannot payout for today or future balances.") if date >= Date.current

    user_ids_to_pay = []

    users.each do |user|
      if self.is_user_payable(
        user, date,
        processor_type: PayoutProcessorType::STRIPE,
        add_comment:,
        from_admin:,
        payout_type: Payouts::PAYOUT_TYPE_INSTANT
      )
        user_ids_to_pay << user.id
        Rails.logger.info("Instant Payouts: Payable user: #{user.id}")
      else
        Rails.logger.info("Instant Payouts: Not payable user: #{user.id}")
      end
    end

    date_string = date.to_s
    if perform_async
      StripePayoutProcessor.enqueue_payments(user_ids_to_pay, date_string, payout_type: Payouts::PAYOUT_TYPE_INSTANT)
    else
      payments = []
      user_ids_to_pay.each do |user_id|
        payments << PayoutUsersService.new(date_string:,
                                           processor_type: PayoutProcessorType::STRIPE,
                                           payout_type: Payouts::PAYOUT_TYPE_INSTANT,
                                           user_ids: user_id).process
      end
      payments.compact
    end
  end

  def self.create_payment(date, processor_type, user, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    payout_processor = ::PayoutProcessorType.get(processor_type)
    balances = mark_balances_processing(date, processor_type, user)
    balance_cents = balances.sum(&:amount_cents)

    if balance_cents <= 0
      Rails.logger.info("Payouts: Negative balance for #{user.id}")
      balances.each(&:mark_unpaid!)
      return nil
    end

    payment = Payment.new(
      user:,
      balances:,
      processor: processor_type,
      processor_fee_cents: 0,
      payout_period_end_date: date,
      payout_type:,
      # TODO: Refactor paypal to be a type of bank account rather than being a field on user.
      payment_address: (user.paypal_payout_email if processor_type == ::PayoutProcessorType::PAYPAL),
      bank_account: (user.active_bank_account if processor_type != ::PayoutProcessorType::PAYPAL)
    )
    payment.save!
    payment_errors = payout_processor.prepare_payment_and_set_amount(payment, balances)
    payment.mark_processing!
    [payment, payment_errors]
  end

  def self.mark_balances_processing(date, processor_type, user)
    user.unpaid_balances_up_to_date(date).select do |balance|
      next if !::PayoutProcessorType.get(processor_type).is_balance_payable(balance)

      balance.with_lock do
        balance.mark_processing!
      end
      true
    end
  end
  private_class_method :mark_balances_processing
end
