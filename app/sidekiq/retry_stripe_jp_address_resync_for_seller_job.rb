# frozen_string_literal: true

# A JP account whose kanji/kana address Stripe never accepted stays charge- and payout-disabled
# until the unchanged address leaves are re-sent; nothing else re-sends them for dormant sellers.
class RetryStripeJpAddressResyncForSellerJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil? || user.suspended? || user.has_stripe_account_connected?
    return if user.current_payout_processor == PayoutProcessorType::PAYPAL
    return if user.stripe_account.blank? || user.alive_user_compliance_info.nil?

    requests = RetryStripeJpAddressResyncsJob.requests_for(user)
    return if requests.empty?

    begin
      StripeMerchantAccountManager.handle_new_user_compliance_info(
        user.alive_user_compliance_info, notify: false, force_address_resync: true
      )
    rescue => e
      Rails.logger.error("RetryStripeJpAddressResyncForSellerJob failed for user #{user.id}: #{e.class}: #{e.message}")
    end

    requests.select(&:requested?).each do |request|
      request.json_data["address_resync_count"] = RetryStripeJpAddressResyncsJob.attempts(request) + 1
      request.json_data["address_resync_at"] = Time.current.iso8601
      request.save!
    end
  end
end
