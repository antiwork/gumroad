# frozen_string_literal: true

# One-time cleanup for accounts Stripe rejected before the account.updated
# webhook handler started closing their verification requests. Closing the
# requests stops the "we need more information" reminder emails, whose
# remediation links dead-end on rejected accounts. Enqueue manually when
# ready to run:
#   CloseComplianceRequestsForStripeRejectedAccountsJob.perform_async
class CloseComplianceRequestsForStripeRejectedAccountsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 5, lock: :until_executed

  def perform
    UserComplianceInfoRequest.requested.distinct.pluck(:user_id).each do |user_id|
      user = User.find_by(id: user_id)
      next if user.nil?
      next unless user.stripe_account&.stripe_rejected?

      user.user_compliance_info_requests.requested.find_each(&:mark_provided!)
      Rails.logger.info("CloseComplianceRequestsForStripeRejectedAccountsJob: closed requests for user #{user.id}")
    end
  end
end
