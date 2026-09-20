# frozen_string_literal: true

# PayPal does not send a webhook when an accepted refund later fails, so reconcile
# pending refunds to ensure failures reach the existing exception queue.
class ReconcilePendingPaypalRefundsJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  # Hourly cron: keep max_attempt under the interval minus
  # RecurringLockTtl::SAFETY_MARGIN so a stranded lock digest cannot mute the next fire.
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 45.minutes

  # PayPal's statuses, with the lowercase values Refund::TERMINAL_FAILURE_STATUSES uses.
  # Both cases are accepted in both directions: a row we failed to recognise would be
  # the silent PENDING this job exists to end.
  PAYPAL_PENDING_STATUSES = %w(PENDING pending).freeze
  PAYPAL_COMPLETED_STATUS = "COMPLETED"
  PAYPAL_TERMINAL_FAILURE_STATUSES = { "FAILED" => "failed", "CANCELLED" => "canceled" }.freeze

  UNREADABLE_PAYPAL_ISSUES = %w(closed_user locked_user not_authorized permission_denied).freeze

  # Only refunds past this age are worth a round-trip; a younger one can still settle. No
  # upper bound, because access to an unreadable refund can be restored later.
  MINIMUM_AGE = 3.days

  def perform
    refunds_to_reconcile.find_each do |refund|
      reconcile(refund)
    rescue StandardError => e
      Rails.logger.error("Reconciling pending PayPal refund #{refund.id} failed: #{e.class}: #{e.message}")
      # Best-effort: notify_unreadable re-raises into this rescue, and a second
      # notify failure must not abort later refunds in this find_each.
      begin
        ErrorNotifier.notify(e, context: { refund_id: refund.id, purchase_id: refund.purchase_id })
      rescue StandardError => notify_error
        Rails.logger.error("ErrorNotifier failed for pending PayPal refund #{refund.id}: #{notify_error.class}: #{notify_error.message}")
      end
    end
  end

  private
    def refunds_to_reconcile
      Refund.joins(:purchase)
            .where(status: PAYPAL_PENDING_STATUSES)
            .where.not(processor_refund_id: [nil, ""])
            .where(purchases: { charge_processor_id: PaypalChargeProcessor.charge_processor_id })
            .where(created_at: ...MINIMUM_AGE.ago)
            .where(<<~SQL.squish)
              COALESCE(refunds.json_data->>'$.paypal_refund_unreadable_at', '') IN ('', 'null')
              OR COALESCE(refunds.json_data->>'$.paypal_refund_unreadable_issue', '') != 'closed_user'
            SQL
    end

    def reconcile(refund)
      purchase = refund.purchase
      processor_status = PaypalChargeProcessor.fetch_refund_status(
        processor_refund_id: refund.processor_refund_id,
        merchant_account: purchase.merchant_account ||
          purchase.seller.merchant_account(PaypalChargeProcessor.charge_processor_id)
      ).to_s.upcase

      case processor_status
      when PAYPAL_COMPLETED_STATUS
        refund.update!(status: PAYPAL_COMPLETED_STATUS)
      when *PAYPAL_TERMINAL_FAILURE_STATUSES.keys
        Purchase::HandleFailedRefundService.new(
          refund:,
          failure_status: PAYPAL_TERMINAL_FAILURE_STATUSES.fetch(processor_status)
        ).perform
      end
    rescue ChargeProcessorError => e
      handle_processor_error(refund, e)
    end

    def handle_processor_error(refund, error)
      issue = unreadable_paypal_issue(error)
      raise error unless issue

      # Lock only the refund here; terminal failure handling takes the purchase lock first.
      refund.with_lock do
        next unless PAYPAL_PENDING_STATUSES.include?(refund.status)

        if refund.paypal_refund_unreadable_at.blank?
          notify_unreadable(refund, error)
          refund.paypal_refund_unreadable_at = Time.current.iso8601
        end
        refund.update!(paypal_refund_unreadable_issue: issue)
      end
    end

    def unreadable_paypal_issue(error)
      issue = error.processor_error_code if error.respond_to?(:processor_error_code)
      # Also accept a plain error-code body, never an issue mentioned in descriptive text.
      issue ||= error.message.to_s[/\A\d{3}\|([a-z_]+)\z/i, 1]
      issue = issue.to_s.downcase
      issue if UNREADABLE_PAYPAL_ISSUES.include?(issue)
    end

    def notify_unreadable(refund, error)
      ErrorNotifier.notify(
        error,
        context: { refund_id: refund.id, purchase_id: refund.purchase_id, paypal_refund_unreadable: true }
      )
    end
end
