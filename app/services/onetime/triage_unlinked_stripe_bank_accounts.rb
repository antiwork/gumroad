# frozen_string_literal: true

# No payout note: Payouts dedupes against the newest note, so a triage breadcrumb would change
# seller-facing behavior. A local match remains provider-unverified, never safe to restore.
module Onetime
  class TriageUnlinkedStripeBankAccounts
    BATCH_SIZE = 500
    # Walked as primary-key windows so every query is an indexed range, however sparse the matches.
    MAX_ID_SPAN = 100_000

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
      dispositions = {}

      (start_id..end_id).step(batch_size) do |window_start|
        dispositions.merge!(triage_window(window_start..[window_start + batch_size - 1, end_id].min))
      end

      puts "[#{self.class.name}] ids=#{start_id}..#{end_id} #{dispositions.values.map { _1[:disposition] }.tally}"
      { dispositions:, next_start_id: end_id + 1, done: end_id >= max_id }
    end

    private
      def triage_window(id_range)
        rows = unlinked_rows.where(id: id_range).to_a
        return {} if rows.empty?

        unpaid_cents = Balance.unpaid.where(user_id: rows.map(&:user_id).uniq).group(:user_id).sum(:amount_cents)
        rows.select! { |row| unpaid_cents[row.user_id].to_i.positive? }
        return {} if rows.empty?

        skip_notes = generic_skip_notes.where(commentable_id: rows.map(&:user_id).uniq)
                                       .where("created_at >= ?", rows.map(&:created_at).min)
                                       .pluck(:commentable_id, :created_at)
                                       .group_by(&:first)
        skip_times = rows.to_h do |row|
          [row.id, Array(skip_notes[row.user_id]).filter_map { |_, at| at if at >= row.created_at }]
        end
        rows.select! { |row| skip_times[row.id].any? }

        results = rows.to_h do |row|
          [row.id, {
            disposition: classify(row),
            user_id: row.user_id,
            bank_account_type: row.type,
            unpaid_balance_cents: unpaid_cents[row.user_id],
            generic_skip_note_count: skip_times[row.id].length,
            latest_generic_skip_at: skip_times[row.id].max,
            provider_identity: "unverified",
          }]
        end

        # A sync can link, replace or delete a row while the window is being classified.
        still_unlinked = unlinked_rows.where(id: results.keys).ids.to_set
        alive_rows_by_user = BankAccount.alive.where(user_id: results.values.map { _1[:user_id] })
                                            .pluck(:user_id, :id).group_by(&:first)
        results.each do |id, result|
          if !still_unlinked.include?(id) ||
             (result[:disposition] == PROVIDER_IDENTITY_UNVERIFIED &&
              alive_rows_by_user[result[:user_id]]&.map(&:last) != [id])
            result[:disposition] = :bank_row_changed_during_scan
          end
        end
        results
      end

      def classify(row)
        user = row.user
        return :no_user if user.nil?

        alive_row_ids = user.bank_accounts.alive.ids
        return :ambiguous_bank_rows if alive_row_ids.many?
        return :bank_row_replaced unless alive_row_ids == [row.id]

        return :risk_hold unless user.compliant?
        return :payouts_paused if user.payouts_paused?
        return :payout_method_changed if user.has_stripe_account_connected? || !user.native_payouts_supported?
        compliance_info = user.alive_user_compliance_info
        return :guardian_required if compliance_info&.under_legal_guardian_age? &&
                                     !compliance_info.legal_guardian_requirement_met?
        return :processing_payment if user.payments.where(state: [Payment::CREATING, Payment::PROCESSING]).exists? ||
                                      user.balances.processing.exists?
        return :india_rail_restricted if india_rail?(row, user)
        return :bank_sync_retry_pending if bank_sync_retry_pending?(user)

        merchant_accounts = user.merchant_accounts.alive.charge_processor_alive.stripe.reject(&:is_a_stripe_connect_account?)
        return :no_merchant_account if merchant_accounts.empty?
        return :ambiguous_merchant_account if merchant_accounts.many? || merchant_accounts.first.charge_processor_merchant_id.blank?

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

      def generic_skip_notes
        Comment.alive
               .with_type_payout_note
               .where(commentable_type: "User", author_id: GUMROAD_ADMIN_ID)
               .where("content LIKE ?", "Payout on % #{Comment.sanitize_sql_like(StripePayoutProcessor::UNLINKED_BANK_ACCOUNT_SKIP_REASON)}")
      end

      def india_rail?(row, user)
        row.is_a?(IndianBankAccount) ||
          StripeMerchantAccountManager::NEW_ACCOUNT_CREATION_BLOCKED_COUNTRIES.include?(user.alive_user_compliance_info&.legal_entity_country_code)
      end

      # RetryStripeRejectedPayoutSetupsJob still owns these rows.
      def bank_sync_retry_pending?(user)
        user.comments
            .alive
            .with_type_payout_note
            .where(author_id: GUMROAD_ADMIN_ID)
            .where("content LIKE ? OR content LIKE ?",
                   "#{StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX}%",
                   "#{StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX}%")
            .any? { |note| note.json_data["abandoned_at"].blank? }
      end
  end
end
