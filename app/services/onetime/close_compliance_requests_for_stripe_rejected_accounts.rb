# frozen_string_literal: true

# One-time cleanup for accounts Stripe rejected before the account.updated
# webhook handler started closing their verification requests. Closing the
# requests stops the "we need more information" reminder emails, whose
# remediation links dead-end on rejected accounts. Run manually from a
# console when ready:
#   Onetime::CloseComplianceRequestsForStripeRejectedAccounts.process
module Onetime
  class CloseComplianceRequestsForStripeRejectedAccounts
    def self.process
      new.process
    end

    def process
      closed = 0
      skipped_appealable = []
      skipped_stripe_error = []

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
            skipped_appealable << user.id
            next
          end
        rescue Stripe::StripeError => e
          Rails.logger.warn("Onetime::CloseComplianceRequestsForStripeRejectedAccounts: skipped user #{user.id} — Stripe lookup failed (#{e.message})")
          skipped_stripe_error << user.id
          next
        end

        user.user_compliance_info_requests.requested.find_each(&:mark_provided!)
        closed += 1
      end

      # The summary is the tripwire for the requirements-exhausted predicate: if
      # most of the backlog lands in skipped_appealable, the predicate is
      # starving the cleanup and needs re-examination. Stripe-error skips are
      # listed so a re-run can target just those users (this is one-time;
      # transient API failures would otherwise be dropped silently).
      Rails.logger.info(
        "Onetime::CloseComplianceRequestsForStripeRejectedAccounts: closed=#{closed} " \
        "skipped_appealable=#{skipped_appealable.size} #{skipped_appealable.inspect} " \
        "skipped_stripe_error=#{skipped_stripe_error.size} #{skipped_stripe_error.inspect}"
      )
    end
  end
end
