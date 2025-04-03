# frozen_string_literal: true

class SendCommunityChatRecapNotificationsJob
  include Sidekiq::Job

  sidekiq_options queue: :low, lock: :until_executed

  def perform(community_chat_recap_run_id)
    recap_run = CommunityChatRecapRun.find(community_chat_recap_run_id)
    return unless recap_run.finished?

    community_recap_ids_by_community = recap_run
      .community_chat_recaps
      .status_finished
      .pluck(:id, :community_id)
      .each_with_object({}) do |(id, community_id), hash|
        hash[community_id] ||= []
        hash[community_id] << id
      end
    return if community_recap_ids_by_community.empty?

    notification_settings_by_user = CommunityNotificationSetting
      .where(recap_frequency: recap_run.recap_frequency)
      .order(:user_id)
      .includes(:user)
      .group_by(&:user_id)
    return if notification_settings_by_user.empty?

    community_ids_by_seller = Community
      .alive
      .where(seller_id: notification_settings_by_user.values.flatten.map(&:seller_id).uniq)
      .pluck(:id, :seller_id)
      .each_with_object({}) do |(id, seller_id), hash|
        hash[seller_id] ||= []
        hash[seller_id] << id
      end
    return if community_ids_by_seller.empty?

    notification_settings_by_user.each do |user_id, settings|
      next if settings.empty?
      accessible_community_ids = settings.first.user.accessible_communities_ids

      settings.each do |setting|
        seller_community_ids = (community_ids_by_seller[setting.seller_id] || []) & accessible_community_ids
        next if seller_community_ids.empty?

        seller_community_recap_ids = seller_community_ids.map { community_recap_ids_by_community[_1] }.flatten.compact
        next if seller_community_recap_ids.empty?

        Rails.logger.info("Sending recap notification to user #{user_id} for seller #{setting.seller_id} for recaps: #{seller_community_recap_ids}")
        CommunityChatRecapMailer.community_chat_recap_notification(
          user_id,
          setting.seller_id,
          seller_community_recap_ids
        ).deliver_later
      end
    end
  rescue => e
    Rails.logger.error("Error sending community recap notifications: #{e.full_message}")
    Bugsnag.notify(e)
  end
end
