# frozen_string_literal: true

class CommunityChatRecapMailerPreview < ActionMailer::Preview
  def community_chat_recap_notification
    CommunityChatRecapMailer.community_chat_recap_notification(User.first.id, User.last.id, CommunityChatRecap.status_finished.where(community_chat_recap_run_id: CommunityChatRecapRun.recap_frequency_daily.finished.pluck(:id)).last(3).pluck(:id))
  end
end
