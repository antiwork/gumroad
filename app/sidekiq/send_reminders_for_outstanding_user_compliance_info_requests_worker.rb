# frozen_string_literal: true

class SendRemindersForOutstandingUserComplianceInfoRequestsWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  TIME_UNTIL_REQUEST_NEEDS_REMINDER = 2.days

  MAX_NUMBER_OF_REMINDERS = 2
  private_constant :MAX_NUMBER_OF_REMINDERS, :TIME_UNTIL_REQUEST_NEEDS_REMINDER

  def perform
    user_ids = UserComplianceInfoRequest.requested.distinct.pluck(:user_id)

    user_ids.each do |user_id|
      user = User.find(user_id)
      return unless user.account_active?
      requests = user.user_compliance_info_requests

      if user.stripe_account&.country == Compliance::Countries::SGP.alpha2
        sg_verification_request = requests.requested.where(field_needed: UserComplianceInfoFields::Individual::STRIPE_ENHANCED_IDENTITY_VERIFICATION).last
        # Stripe account is permanently closed if not updated in 120 days, so do not send reminders after that.
        # Ref: https://stripe.com/en-in/guides/sg-payment-services-act-2019#account-closure
        sg_verification_deadline = user.stripe_account.created_at + 120.days
        if sg_verification_request.present? && Time.current < sg_verification_deadline &&
          (sg_verification_request.sg_verification_reminder_sent_at.nil? || sg_verification_request.sg_verification_reminder_sent_at < 7.days.ago)
          ContactingCreatorMailer.singapore_identity_verification_reminder(user_id, sg_verification_deadline).deliver_later(queue: "default")
          sg_verification_request.sg_verification_reminder_sent_at = Time.current
          sg_verification_request.save!
        end
      end

      oldest_request = requests.first

      should_remind = (oldest_request.last_email_sent_at.nil? || oldest_request.last_email_sent_at < TIME_UNTIL_REQUEST_NEEDS_REMINDER.ago) &&
                      oldest_request.emails_sent_at.count < MAX_NUMBER_OF_REMINDERS

      next unless should_remind

      ContactingCreatorMailer.payouts_may_be_blocked(user_id).deliver_later(queue: "critical")
      email_sent_at = Time.current
      requests.each { |request| request.record_email_sent!(email_sent_at) }
    end
  end
end
