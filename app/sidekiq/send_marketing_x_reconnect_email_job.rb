# frozen_string_literal: true

class SendMarketingXReconnectEmailJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed

  def perform(marketing_action_id)
    action = Marketing::Action.find_by(id: marketing_action_id)
    return if action.nil?

    action.user.with_lock do
      actions = Marketing::Action.alive_for_reconnect_notice.where(user_id: action.user_id).order(:id).lock.to_a
      next if actions.empty?

      # Keep selection and delivery together: cancelling one product must not consume its siblings.
      # A crash after delivery but before commit can repeat the email on retry.
      delivered = CreatorMailer.marketing_x_reconnect(marketing_action_id: actions.first.id).deliver_now
      next unless delivered.is_a?(Mail::Message)

      Marketing::Action.where(id: actions.map(&:id)).update_all(reconnect_notified_at: Time.current)
    end
  end
end
