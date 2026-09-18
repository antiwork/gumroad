# frozen_string_literal: true

class SendMarketingXReconnectEmailJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed

  # Delivery is an SMTP call, so it stays outside the lock: holding the seller's rows across
  # it would block approve, cancel and post until SMTP times out. The claim is still made only
  # against a real delivery, and re-reading the eligible set afterwards means a product
  # cancelled mid-send is not consumed. Two jobs racing for one seller can double-send; the
  # unique lock covers the common case of the same action failing twice.
  def perform(marketing_action_id)
    action = Marketing::Action.find_by(id: marketing_action_id)
    return if action.nil?

    pending_ids = action.user.with_lock { eligible_for(action).pluck(:id) }
    return if pending_ids.empty?

    delivered = CreatorMailer.marketing_x_reconnect(marketing_action_id: pending_ids.first).deliver_now
    return unless delivered.is_a?(Mail::Message)

    action.user.with_lock do
      eligible_for(action).where(id: pending_ids).update_all(reconnect_notified_at: Time.current)
    end
  end

  private
    def eligible_for(action)
      Marketing::Action.alive_for_reconnect_notice.where(user_id: action.user_id).order(:id)
    end
end
