# frozen_string_literal: true

class SyncStuckPayoutsJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  # Two static-arg entries (daily STRIPE, weekly PAYPAL), so each digest is constant. The attempt
  # is one processor round-trip per stuck payout, and a wide backlog is exactly when it is slow.
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 2.hours

  # PayPal's TransactionSearch only searches the last three years, and the sync searches from the
  # day before the payout was created. A PayPal payout older than that can therefore never be
  # found: every weekly run raised "No PayPal transaction found" once for each of the ~670 payouts
  # from 2012-2020, and that volume on its own trips the production error-spike alert.
  #
  # Their state is deliberately left alone — reverting #8111 established that an empty search cannot
  # tell a returned payout from a claimed payout whose IPN we missed, so failing or cancelling them
  # risks paying the same money twice. There is nothing to sync for them, so they are not searched.
  PAYPAL_TRANSACTION_SEARCH_HORIZON = 3.years

  def perform(processor)
    stuck_payments(processor).find_each do |payment|
      Rails.logger.info("Syncing #{processor} payout #{payment.id} stuck in #{payment.state} state")

      begin
        payment.sync_with_payout_processor
      rescue => e
        Rails.logger.error("Error syncing #{processor} payout #{payment.id}: #{e.message}")
        ErrorNotifier.notify(e)
        next
      end

      if payment.errors.any?
        message = "Syncing #{processor} payout #{payment.id} rejected: #{payment.errors.full_messages.join(', ')}"
        Rails.logger.error(message)
        # Stripe reverse_internal_transfer_or_hold_payouts! already sent the rich Sentry event.
        # A second "rejected sync" alert is noise for that same incident.
        ErrorNotifier.notify(message) unless payment.instance_variable_get(:@payout_reversal_failure_notified)
        next
      end

      Rails.logger.info("Payout #{payment.id} synced to #{payment.state} state")
    end
  end

  private
    def stuck_payments(processor)
      stuck_payment_states = %w(creating processing)
      stuck_payment_states << "unclaimed" if processor != PayoutProcessorType::STRIPE

      base_scope = Payment.where(processor:, state: stuck_payment_states)

      if processor == PayoutProcessorType::PAYPAL
        # One day of slack so a payout sitting right on the horizon still gets its one attempt.
        return base_scope.where("created_at >= ?", PAYPAL_TRANSACTION_SEARCH_HORIZON.ago - 1.day)
      end

      return base_scope if processor != PayoutProcessorType::STRIPE

      base_scope.where(
        "(state = 'creating' AND created_at < :creating_cutoff) OR " \
        "(state = 'processing' AND (" \
          "(JSON_EXTRACT(json_data, '$.arrival_date') IS NOT NULL AND FROM_UNIXTIME(JSON_EXTRACT(json_data, '$.arrival_date')) < :today) OR " \
          "(JSON_EXTRACT(json_data, '$.arrival_date') IS NULL AND created_at < :processing_cutoff)" \
        "))",
        creating_cutoff: 24.hours.ago,
        today: Date.current,
        processing_cutoff: 3.days.ago
      )
    end
end
