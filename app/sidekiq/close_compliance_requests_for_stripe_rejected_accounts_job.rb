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

      # Not every `rejected.*` account is terminal: Stripe sometimes keeps a
      # verification requirement open on a rejected account (appealable
      # rejection, e.g. Japan `rejected.listed` with a live identity-document
      # request). Ask Stripe before closing anything — if the account still
      # has open requirements, the seller can still remediate and their
      # requests must stay open.
      begin
        stripe_account = Stripe::Account.retrieve(user.stripe_account.charge_processor_merchant_id)
        requirements = stripe_account["requirements"] || {}
        future_requirements = stripe_account["future_requirements"] || {}
        unless StripeMerchantAccountManager.stripe_requirements_exhausted?(requirements, future_requirements)
          Rails.logger.info("CloseComplianceRequestsForStripeRejectedAccountsJob: skipped user #{user.id} — rejected but Stripe still has open requirements (appealable)")
          next
        end
      rescue Stripe::StripeError => e
        Rails.logger.warn("CloseComplianceRequestsForStripeRejectedAccountsJob: skipped user #{user.id} — Stripe lookup failed (#{e.message})")
        next
      end

      user.user_compliance_info_requests.requested.find_each(&:mark_provided!)
      Rails.logger.info("CloseComplianceRequestsForStripeRejectedAccountsJob: closed requests for user #{user.id}")
    end
  end
end
