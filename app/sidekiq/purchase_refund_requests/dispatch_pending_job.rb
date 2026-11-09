# frozen_string_literal: true

# Durable side of the refund-request notifications and the escalation deadline:
# the open rows are the source of truth, so a lost or failed Sidekiq push is
# picked up on the next run.
class PurchaseRefundRequests::DispatchPendingJob
  include Sidekiq::Job
  include DatabaseRoleRouting
  sidekiq_options retry: 5, queue: :low

  # Leaves room for the create-time NotifyJob push to run first.
  NOTIFICATION_GRACE_PERIOD = 10.minutes
  # Stops re-pushing a seller email that never goes through (e.g. a bad address).
  OWED_NOTIFICATION_RETRY_WINDOW = 30.days

  def perform
    with_primary_database do
      # open_key is set only while a request is open, so this walks the unique index.
      PurchaseRefundRequest.where.not(open_key: nil).includes(purchase: :seller).find_each do |refund_request|
        next unless refund_request.open?
        next unless Feature.active?(:buyer_refund_requests, refund_request.purchase.seller)

        if refund_request.notifications_pending? && refund_request.created_at <= NOTIFICATION_GRACE_PERIOD.ago
          PurchaseRefundRequests::NotifyJob.perform_async(refund_request.id)
        end
        PurchaseRefundRequests::EscalateJob.perform_async(refund_request.id) if refund_request.escalation_deadline.past?
      end

      # Escalation clears open_key, so a seller email still owed then is retried from here.
      PurchaseRefundRequest.state_escalated.where(seller_notified_at: nil, created_at: OWED_NOTIFICATION_RETRY_WINDOW.ago..)
                           .includes(purchase: :seller).find_each do |refund_request|
        next unless Feature.active?(:buyer_refund_requests, refund_request.purchase.seller)

        PurchaseRefundRequests::NotifyJob.perform_async(refund_request.id)
      end
    end
  end
end
