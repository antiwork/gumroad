# frozen_string_literal: true

# No payout note: Payouts dedupes against the newest note, so a triage breadcrumb would change
# seller-facing behavior. A local match remains provider-unverified, never safe to restore.
module Onetime
  class TriageUnlinkedStripeBankAccounts
    BATCH_SIZE = 500
    # Walked as primary-key windows so every query is an indexed range, however sparse the matches.
    MAX_ID_SPAN = 100_000
    # The payout predicates are scoped model methods, so each classified row still costs a bounded
    # handful of queries. A dense range stops here and resumes from next_start_id.
    MAX_CLASSIFIED_ROWS = 50
    MAX_UNPAID_BALANCES_PER_USER = 200

    PROVIDER_IDENTITY_UNVERIFIED = :provider_identity_unverified

    def self.process(start_id: 1, end_id: nil, batch_size: BATCH_SIZE)
      new.process(start_id:, end_id:, batch_size:)
    end

    def process(start_id: 1, end_id: nil, batch_size: BATCH_SIZE)
      raise ArgumentError, "start_id must be a positive integer" unless start_id.is_a?(Integer) && start_id.positive?
      raise ArgumentError, "batch_size must be between 1 and #{BATCH_SIZE}" unless batch_size.is_a?(Integer) && batch_size.between?(1, BATCH_SIZE)
      raise ArgumentError, "end_id must not precede start_id" if !end_id.nil? && (!end_id.is_a?(Integer) || end_id < start_id)

      max_id = BankAccount.maximum(:id).to_i
      return { dispositions: {}, next_start_id: start_id, done: true } if start_id > max_id

      last_allowed_id = [start_id + MAX_ID_SPAN - 1, max_id].min
      end_id = end_id.nil? ? last_allowed_id : [end_id, last_allowed_id].min
      scanned_through = end_id
      dispositions = {}

      (start_id..end_id).step(batch_size) do |window_start|
        budget = MAX_CLASSIFIED_ROWS - dispositions.size
        if budget.zero?
          scanned_through = window_start - 1
          break
        end

        results, truncated_at = triage_window(window_start..[window_start + batch_size - 1, end_id].min, budget)
        dispositions.merge!(results)
        if truncated_at
          scanned_through = truncated_at
          break
        end
      end

      puts "[#{self.class.name}] ids=#{start_id}..#{scanned_through} #{dispositions.values.map { _1[:disposition] }.tally}"
      { dispositions:, next_start_id: scanned_through + 1, done: scanned_through >= max_id }
    end

    private
      def triage_window(id_range, budget)
        rows = unlinked_rows.where(id: id_range).order(:id).to_a
        return [{}, nil] if rows.empty?

        # Balance#amount_cents is the USD ledger for every holding currency. This total only picks
        # candidates; it is not one payable sum (see :negative_balance_group).
        unpaid_usd_cents = Balance.unpaid.where(user_id: rows.map(&:user_id).uniq).group(:user_id).sum(:amount_cents)
        rows.select! { |row| unpaid_usd_cents[row.user_id].to_i.positive? }
        return [{}, nil] if rows.empty?

        notes_for_rows = generic_skip_notes
                         .joins("INNER JOIN bank_accounts ON bank_accounts.user_id = comments.commentable_id")
                         .where(bank_accounts: { id: rows.map(&:id) })
                         .where("comments.created_at >= bank_accounts.created_at")
                         .group("bank_accounts.id")
        skip_counts = notes_for_rows.count
        latest_skip_at = notes_for_rows.maximum("comments.created_at")
        rows.select! { |row| skip_counts[row.id].to_i.positive? }

        truncated_at = rows[budget - 1].id if rows.size > budget
        rows = rows.first(budget)
        return [{}, truncated_at] if rows.empty?

        context = window_context(rows.map(&:user_id).uniq)
        results = rows.to_h do |row|
          oversized_history = context[:oversized_balance_history_user_ids].include?(row.user_id)
          balances = context[:unpaid_balances].fetch(row.user_id, [])
          user = context[:users][row.user_id]
          weekly_schedule = user && [User::PayoutSchedule::WEEKLY, User::PayoutSchedule::DAILY].include?(user.payout_frequency)
          window_end_date = next_weekly_payout_cutoff(row) if weekly_schedule && PayoutRailSchedule.scheduled_bank_account_type?(row.type)
          payout_window_balances = window_end_date ? balances.select { _1.date <= window_end_date } : []
          [row.id, {
            disposition: classify(row, context, payout_window_balances:),
            user_id: row.user_id,
            bank_account_type: row.type,
            unpaid_usd_ledger_cents: unpaid_usd_cents[row.user_id],
            payout_window_usd_ledger_cents: (payout_window_balances.sum(&:amount_cents) if window_end_date && !oversized_history),
            payout_window_end_date: window_end_date,
            generic_skip_note_count: skip_counts[row.id],
            latest_generic_skip_at: latest_skip_at[row.id],
            provider_identity: "unverified",
          }]
        end

        # A sync can link, replace or delete a row while the window is being classified.
        still_unlinked = unlinked_rows.where(id: results.keys).ids.to_set
        alive_rows_by_user = alive_bank_row_ids_by_user(results.values.map { _1[:user_id] })
        results.each do |id, result|
          if !still_unlinked.include?(id) ||
             (result[:disposition] == PROVIDER_IDENTITY_UNVERIFIED && alive_rows_by_user[result[:user_id]] != [id])
            result[:disposition] = :bank_row_changed_during_scan
          end
        end
        [results, truncated_at]
      end

      # One query per lookup for the whole window, so only the model predicates in classify cost
      # anything per row.
      def window_context(user_ids)
        balance_counts = Balance.unpaid.where(user_id: user_ids).group(:user_id).count
        oversized_ids = balance_counts.filter_map { |id, count| id if count > MAX_UNPAID_BALANCES_PER_USER }
        {
          oversized_balance_history_user_ids: oversized_ids.to_set,
          users: User.where(id: user_ids).index_by(&:id),
          alive_bank_row_ids: alive_bank_row_ids_by_user(user_ids),
          in_flight_user_ids: (Payment.where(user_id: user_ids, state: [Payment::CREATING, Payment::PROCESSING]).distinct.pluck(:user_id) +
                               Balance.processing.where(user_id: user_ids).distinct.pluck(:user_id)).to_set,
          bank_sync_retry_pending_user_ids: bank_sync_retry_pending_user_ids(user_ids),
          stripe_accounts: MerchantAccount.alive.charge_processor_alive.stripe.where(user_id: user_ids)
                                          .reject(&:is_a_stripe_connect_account?).group_by(&:user_id),
          unpaid_balances: Balance.unpaid.where(user_id: user_ids - oversized_ids).includes(:merchant_account).group_by(&:user_id),
        }
      end

      def next_weekly_payout_cutoff(row)
        cycle_date = User::PayoutSchedule.next_scheduled_payout_date
        weekday = PayoutRailSchedule.weekday_for_bank_account_type(row.type)
        days_before_cycle = (PayoutRailSchedule::WEEKDAYS.index(:friday) - PayoutRailSchedule::WEEKDAYS.index(weekday)) % 7
        rail_date = cycle_date - days_before_cycle
        # Bank-rail jobs start at 10:00 UTC; midnight is still the current payout cycle.
        scheduled_rail_start = Time.utc(rail_date.year, rail_date.month, rail_date.day, 10)
        cycle_date += 7 if Time.current.utc >= scheduled_rail_start
        cycle_date - User::PayoutSchedule::PAYOUT_DELAY_DAYS
      end

      def classify(row, context, payout_window_balances:)
        user = context[:users][row.user_id]
        return :no_user if user.nil?

        alive_row_ids = context[:alive_bank_row_ids].fetch(user.id, [])
        return :ambiguous_bank_rows if alive_row_ids.many?
        return :bank_row_replaced unless alive_row_ids == [row.id]

        return :risk_hold unless user.compliant?
        compliance_info = user.alive_user_compliance_info
        return :guardian_required if compliance_info&.under_legal_guardian_age? &&
                                     !compliance_info.legal_guardian_requirement_met?
        return :chargeback_reserve_active if user.chargeback_rate_payout_reserve_active?
        return :payouts_paused if user.payouts_paused?
        return :payout_method_changed if user.has_stripe_account_connected? || !user.native_payouts_supported?
        return :processing_payment if context[:in_flight_user_ids].include?(user.id)
        return :balance_history_requires_review if context[:oversized_balance_history_user_ids].include?(user.id)
        return :no_payout_rail unless PayoutRailSchedule.scheduled_bank_account_type?(row.type)
        return :payout_schedule_requires_review unless [User::PayoutSchedule::WEEKLY, User::PayoutSchedule::DAILY].include?(user.payout_frequency)

        # An unlinked row cannot pass the instant path, so the standard weekly rail is the useful bound.
        balances = context[:unpaid_balances].fetch(user.id, [])
        return :below_payout_minimum if payout_window_balances.sum(&:amount_cents) < user.minimum_payout_amount_cents
        return :india_rail_restricted if india_rail?(row, compliance_info)
        return :bank_sync_retry_pending if context[:bank_sync_retry_pending_user_ids].include?(user.id)

        merchant_accounts = context[:stripe_accounts].fetch(user.id, [])
        return :no_merchant_account if merchant_accounts.empty?
        return :ambiguous_merchant_account if merchant_accounts.many? || merchant_accounts.first.charge_processor_merchant_id.blank?
        # Keep both the full ledger and the next payout window fail-closed.
        return :negative_balance_group if [balances, payout_window_balances].any? do |set|
          StripePayoutProcessor.payout_groups(user, set).any? { |_, _, group| group.sum(&:amount_cents).negative? }
        end

        return :debit_card_row if row.is_a?(CardBankAccount)
        # IBAN rows have no routing number, so the #7882 identity match can never prove them.
        return :missing_routing if row.stripe_external_account_routing_number.blank?
        return :missing_bank_details if [row.account_number_last_four, row.stripe_external_account_currency,
                                         row.stripe_external_account_country].any?(&:blank?)

        PROVIDER_IDENTITY_UNVERIFIED
      end

      def unlinked_rows
        BankAccount.alive.where(stripe_bank_account_id: [nil, ""])
      end

      def alive_bank_row_ids_by_user(user_ids)
        BankAccount.alive.where(user_id: user_ids).order(:id).pluck(:user_id, :id)
                   .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      end

      def generic_skip_notes
        Comment.alive
               .with_type_payout_note
               .where(commentable_type: "User", author_id: GUMROAD_ADMIN_ID)
               .where("content LIKE ?", "Payout on % #{Comment.sanitize_sql_like(StripePayoutProcessor::UNLINKED_BANK_ACCOUNT_SKIP_REASON)}")
      end

      def india_rail?(row, compliance_info)
        row.is_a?(IndianBankAccount) ||
          StripeMerchantAccountManager::NEW_ACCOUNT_CREATION_BLOCKED_COUNTRIES.include?(compliance_info&.legal_entity_country_code)
      end

      # RetryStripeRejectedPayoutSetupsJob still owns these rows.
      def bank_sync_retry_pending_user_ids(user_ids)
        Comment.alive
               .with_type_payout_note
               .where(commentable_type: "User", commentable_id: user_ids, author_id: GUMROAD_ADMIN_ID)
               .where("content LIKE ? OR content LIKE ?",
                      "#{StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX}%",
                      "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}%")
               .select { |note| note.json_data["abandoned_at"].blank? }
               .to_set(&:commentable_id)
      end
  end
end
