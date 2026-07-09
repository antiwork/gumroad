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
      # `next`, not `return`: an inactive (deleted or suspended) user should
      # only be skipped — returning here would silently stop reminders for
      # every user later in the list.
      next unless user.account_active?
      # Terminally rejected Stripe accounts are final: the verification these
      # reminders ask for can't change Stripe's decision, so don't nag the
      # seller. Their open requests get closed by the account.updated webhook
      # handler; this guard covers the window before that runs (and legacy
      # rows the backfill hasn't reached yet). Appealable rejections — Stripe
      # rejected the account but is still asking for something, like an
      # identity document — must keep getting reminders, so we ask Stripe
      # whether anything is still requestable before going quiet.
      next if terminally_rejected?(user.stripe_account)
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

  private
    # A rejected Stripe account is terminal only when Stripe has nothing
    # further the seller could submit. When Stripe still lists open
    # requirements on a rejected account (an appealable rejection, e.g. the
    # Japan "rejected.listed" case where an identity document is still
    # wanted), the seller can be reinstated, so they must keep receiving
    # reminders. We ask Stripe directly because both forks look identical
    # locally: each has a rejected merchant account and open compliance
    # request rows.
    def terminally_rejected?(merchant_account)
      return false unless merchant_account&.stripe_rejected?

      stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
      StripeMerchantAccountManager.stripe_requirements_exhausted?(
        stripe_account["requirements"] || {},
        stripe_account["future_requirements"] || {}
      )
    rescue Stripe::StripeError => e
      # Can't tell which fork this is, so stay quiet for this run rather than
      # risk nagging a terminally rejected seller with a dead-end link. The
      # worker runs again and will retry the lookup then.
      Rails.logger.warn("SendRemindersForOutstandingUserComplianceInfoRequestsWorker: treating merchant account #{merchant_account.id} as terminally rejected — Stripe lookup failed (#{e.message})")
      true
    end
end
