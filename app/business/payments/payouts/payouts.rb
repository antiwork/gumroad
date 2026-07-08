# frozen_string_literal: true

class Payouts
  extend ActionView::Helpers::NumberHelper

  MIN_AMOUNT_CENTS = 100_00
  PAYOUT_TYPE_STANDARD = "standard"
  PAYOUT_TYPE_INSTANT = "instant"
  BANK_ACCOUNT_LOOKUP_BATCH_SIZE = 10_000
  HOLDING_BALANCE_ID_BATCH_SIZE = 25_000
  # Max user ids per `User.where(id: ...)` lookup. See the comment in
  # create_payments_for_balances_up_to_date_for_bank_account_types for why a large
  # IN() list has to be split before it reaches MySQL.
  USER_LOOKUP_BATCH_SIZE = 1_000

  def self.is_user_payable(user, date, processor_type: nil, add_comment: false, from_admin: false, bypass_minimum_payout: false, payout_type: Payouts::PAYOUT_TYPE_STANDARD)
    payout_date = Time.current.to_fs(:formatted_date_full_month)

    amount_payable = user.unpaid_balance_cents_up_to_date(date)
    account_balance = amount_payable + user.paid_payments_cents_for_date(date)
    below_minimum = account_balance < user.minimum_payout_amount_cents

    unless user.compliant? || from_admin
      if add_comment
        if user.not_reviewed? && below_minimum && account_balance > 0
          # A not-reviewed account isn't under any active review — the actual
          # blocker for the seller is the below-minimum balance, so say that.
          add_below_minimum_payout_note(user, payout_date, account_balance)
        else
          reason = user.not_reviewed? ? "under review" : "not compliant"
          user.add_payout_note(content: "Payout on #{payout_date} was skipped because the account was #{reason}.")
        end
      end
      return false
    end

    if user.payouts_paused?
      payouts_paused_by = user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE ? "payout processor" : user.payouts_paused_by_source
      user.add_payout_note(content: "Payout on #{payout_date} was skipped because payouts on the account were paused by the #{payouts_paused_by}.") if add_comment
      return false
    end

    if below_minimum
      is_payable_from_admin = from_admin && account_balance > 0 &&
        (bypass_minimum_payout || user.unpaid_balance_cents_up_to_date_held_by_gumroad(date) == account_balance)

      unless is_payable_from_admin
        add_below_minimum_payout_note(user, payout_date, account_balance) if add_comment && account_balance > 0
        return false
      end
    end

    if payout_type == Payouts::PAYOUT_TYPE_INSTANT
      if !user.instant_payouts_supported?
        user.add_payout_note(content: "Payout on #{payout_date} was skipped because the account is not eligible for instant payouts.") if add_comment
        return false
      end

      amount_payable = user.instantly_payable_unpaid_balance_cents_up_to_date(date)

      if amount_payable < MIN_AMOUNT_CENTS && add_comment && user.unpaid_balance_cents_up_to_date(date) >= MIN_AMOUNT_CENTS
        user.add_payout_note(content: "Instant Payout on #{payout_date} was skipped because funds are still settling. This should resolve within 1-2 days.")
        return false
      end
    end

    processor_types = processor_type ? [processor_type] : ::PayoutProcessorType.all
    processor_types.any? do |payout_processor_type|
      ::PayoutProcessorType.get(payout_processor_type).is_user_payable(user, amount_payable, add_comment:, from_admin:, payout_type:)
    end
  end

  def self.add_below_minimum_payout_note(user, payout_date, account_balance)
    current_balance = user.formatted_dollar_amount(account_balance)
    minimum_balance = user.formatted_dollar_amount(user.minimum_payout_amount_cents)
    user.add_payout_note(content: "Your payout on #{payout_date} was skipped because your balance of #{current_balance} was below the #{minimum_balance} minimum. You'll be paid out automatically once your balance reaches #{minimum_balance}.")
  end
  private_class_method :add_below_minimum_payout_note

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
    # Materialize the holding-balance user ids first, then look up bank accounts in
    # chunks by user_id (indexed). The previous single statement joined
    # users × balances × bank_accounts, and MySQL drove it from a full scan of
    # bank_accounts (no index on `type`), repeatedly blowing the 5-minute statement
    # cap at the scheduled slot and aborting entire payout batches. Splitting the
    # query leaves no join for the optimizer to get wrong, and each piece stays far
    # under the statement cap.
    holding_balance_user_ids = self.holding_balance_user_ids

    bank_account_types.each do |bank_account_type|
      user_ids = holding_balance_user_ids.each_slice(BANK_ACCOUNT_LOOKUP_BATCH_SIZE).flat_map do |user_ids_batch|
        BankAccount.alive.where(user_id: user_ids_batch, type: bank_account_type).distinct.pluck(:user_id)
      end

      # Load the matched users in id-bounded slices rather than one
      # `User.where(id: user_ids)`. For a large bank-account cohort that id list runs
      # to tens of thousands of ids, and MySQL abandons the primary-key range plan
      # once the IN() list outgrows the range optimizer's memory budget
      # (range_optimizer_max_mem_size), falling back to a full scan of the very large
      # users table. That scan can't finish inside the statement timeout, so the whole
      # per-bank-type payout job dies (gumroad-private#955). Slicing keeps every lookup
      # on the fast primary-key range plan. This path is Stripe-only and enqueues one
      # job per user, so processing the cohort a slice at a time is equivalent to
      # processing it all at once.
      user_ids.each_slice(USER_LOOKUP_BATCH_SIZE) do |user_ids_batch|
        users = User.where(id: user_ids_batch)
        self.create_payments_for_balances_up_to_date_for_users(date, processor_type, users, perform_async: true, bank_account_type:)
      end
    end
  end

  # Returns the ids of every user holding a positive unpaid balance — the same set
  # as User.holding_balance — but computed in bounded batches so that no single SQL
  # statement has to aggregate the entire balances table in one go.
  #
  # The single-statement version (users JOIN balances GROUP BY user, or even
  # User.holding_balance.ids on its own) aggregates every unpaid balance row on the
  # platform in one query. That query's runtime grows with the size of the platform,
  # and during the contended 10:00 UTC scheduled-jobs window it has repeatedly
  # exceeded MySQL's 5-minute statement cap, killing whole payout batches
  # (StatementTimeout incidents on 2026-05-26, 07-02, and 07-07). Retries don't help
  # because they land in the same contention window.
  #
  # Instead we walk balances.user_id in ascending order with a keyset cursor
  # (`user_id > last seen id`), aggregating at most HOLDING_BALANCE_ID_BATCH_SIZE
  # users' balances per statement and applying the "sum is positive" filter in Ruby.
  # The positivity check deliberately lives here and not in a SQL HAVING clause:
  # HAVING filters groups after aggregation but before LIMIT, so a long run of
  # users with zero or negative net balances would force one statement to keep
  # aggregating until it found enough positive ones — reintroducing unbounded work.
  # Grouping without HAVING lets MySQL stream exactly LIMIT groups off the
  # `(state, user_id, amount_cents)` covering index and stop, so each statement's
  # work is bounded by the batch size — not by how many sellers Gumroad has. A
  # user's balance rows all share one user_id, so partitioning by user_id ranges
  # never splits a user's SUM across batches, and the union of batches is exactly
  # the users with SUM > 0.
  #
  # One deliberate difference from the JOIN version: this reads only the balances
  # table, so a balance row pointing at a deleted/nonexistent user id would be
  # included here where the JOIN would have dropped it. That cannot change who gets
  # paid — every caller resolves these ids through `User.where(id: ...)`, which
  # drops ids without a users row.
  #
  # Balances don't move out of the `unpaid` state while this worker is only reading,
  # so re-running after a partial failure re-selects the same users; actual payout
  # creation stays idempotent downstream (per-user jobs are deduplicated and
  # Payouts.create_payment no-ops once a user's balances leave `unpaid`).
  def self.holding_balance_user_ids
    user_ids = []
    last_user_id = 0

    loop do
      batch = Balance.unpaid
                     .where("user_id > ?", last_user_id)
                     .group(:user_id)
                     .order(:user_id)
                     .limit(HOLDING_BALANCE_ID_BATCH_SIZE)
                     .pluck(:user_id, Arel.sql("SUM(amount_cents)"))
      break if batch.empty?

      user_ids.concat(batch.filter_map { |user_id, amount_cents| user_id if amount_cents > 0 })
      last_user_id = batch.last.first
    end

    user_ids
  end

  def self.create_instant_payouts_for_balances_up_to_date(date)
    users = User.holding_balance.where("json_data->'$.payout_frequency' = 'daily'")
    self.create_instant_payouts_for_balances_up_to_date_for_users(date, users, perform_async: true, add_comment: true)
  end

  def self.create_payments_for_balances_up_to_date_for_users(date, processor_type, users, perform_async: false, retrying: false, bank_account_type: nil, from_admin: false, bypass_minimum_payout: false)
    raise ArgumentError.new("Cannot payout for today or future balances.") if date >= Date.current

    user_ids_to_pay = []

    users.each do |user|
      if self.is_user_payable(
        user, date,
        processor_type:,
        add_comment: true,
        from_admin:,
        bypass_minimum_payout:
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
    payout_processor = ::PayoutProcessorType.get(processor_type)
    payable_balances = user.unpaid_balances_up_to_date(date).select do |balance|
      payout_processor.is_balance_payable(balance)
    end

    if payout_processor.respond_to?(:filter_aggregate_payable_balances)
      payable_balances = payout_processor.filter_aggregate_payable_balances(user, payable_balances)
    end

    payable_balances.each do |balance|
      balance.with_lock { balance.mark_processing! }
    end
    payable_balances
  end
  private_class_method :mark_balances_processing
end
