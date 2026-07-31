# frozen_string_literal: true

class SendMembershipsPriceUpdateEmailsJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform
    SubscriptionPlanChange.includes(:subscription)
      .applicable_for_product_price_change_as_of(7.days.from_now.to_date)
      .where(notified_subscriber_at: nil)
      .find_each do |subscription_plan_change|
        next unless subscription_plan_change.price_change_notification_recipient_eligible?

        claim_id = subscription_plan_change.claim_price_change_notification
        next unless claim_id

        begin
          job = SendMembershipPriceUpdateEmailJob.perform_later(subscription_plan_change.id, claim_id)
          raise "Membership price update notification was not enqueued" unless job
        rescue
          begin
            subscription_plan_change.release_price_change_notification_claim(claim_id)
          rescue => release_error
            Rails.logger.error(
              "SendMembershipsPriceUpdateEmailsJob could not release the notification claim for " \
              "subscription plan change #{subscription_plan_change.id}: " \
              "#{release_error.class}: #{release_error.message}"
            )
            ErrorNotifier.notify(release_error)
          end
          raise
        end
      end
  end
end
