# frozen_string_literal: true

class SendMissedPostsForPurchaseJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed

  def perform(purchase_id, workflow_id = nil)
    purchase = Purchase.find(purchase_id)
    return unless purchase.can_contact?
    return unless purchase.seller.eligible_to_send_emails?

    MissedPostsDeliveryService.new(purchase:).deliver_all(workflow_id:)

    CheckMissedPostsCompletionJob.perform_in(2.minutes, purchase_id, workflow_id)
  end
end
