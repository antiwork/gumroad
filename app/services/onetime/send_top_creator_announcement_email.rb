# frozen_string_literal: true

class Onetime::SendTopCreatorAnnouncementEmail < Onetime::Base
  LAST_PROCESSED_USER_ID_KEY = "send_top_creator_announcement_email_last_user_id"

  def self.reset_last_processed_user_id
    $redis.del(LAST_PROCESSED_USER_ID_KEY)
  end

  def process
    User.alive.not_suspended
      .where(verified: true)
      .where("id > ?", $redis.get(LAST_PROCESSED_USER_ID_KEY).to_i)
      .order(:id)
      .find_each do |user|
        next if user.form_email.blank?

        CreatorMailer.top_creator_announcement(user_id: user.id).deliver_later(queue: "low")
        $redis.set(LAST_PROCESSED_USER_ID_KEY, user.id)
        Rails.logger.info "Enqueued top_creator_announcement email for user #{user.id}"
      end
  end
end
