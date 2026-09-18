# frozen_string_literal: true

class SendMarketingXReconnectEmailJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed

  # Claiming the row before delivery is what makes this send once. Two executes of the same
  # action enqueue two jobs, and the second finds nothing left to claim.
  def perform(marketing_action_id)
    action = Marketing::Action.find_by(id: marketing_action_id)
    return if action.nil?

    claimed = action.with_lock do
      next false unless Marketing::Action.alive_for_reconnect_notice.exists?(id: action.id)

      action.update!(reconnect_notified_at: Time.current)
      true
    end
    return unless claimed

    CreatorMailer.marketing_x_reconnect(marketing_action_id: action.id).deliver_later
  end
end
