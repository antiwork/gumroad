# frozen_string_literal: true

class PurchaseRefundRequests::EscalateOverdueJob
  include Sidekiq::Job
  include DatabaseRoleRouting
  sidekiq_options retry: 0, queue: :low, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 10.minutes

  def perform
    # Primary: a lagging replica could show a request as unescalated after the last run set it.
    with_primary_database do
      PurchaseRefundRequest.escalation_candidates.includes(purchase: [:link, :seller]).find_each do |refund_request|
        next unless refund_request.escalation_due?
        next unless Feature.active?(:buyer_refund_requests, refund_request.purchase.seller)

        refund_request.escalate!
      rescue => e
        # One failing request must not hold back the others; the next run retries it.
        ErrorNotifier.notify(e, context: { refund_request_id: refund_request.id })
      end
    end
  end
end
