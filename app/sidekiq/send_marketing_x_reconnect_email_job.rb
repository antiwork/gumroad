# frozen_string_literal: true

class SendMarketingXReconnectEmailJob
  include Sidekiq::Job
  sidekiq_options queue: :low, lock: :until_executed

  # Enqueue first, record second, both under the row lock. Recording first would strand the
  # seller for good if the worker died before the enqueue: the retry would see the claim and
  # exit. This way the worst case is a duplicate nudge, which beats silence. Concurrent jobs
  # serialize on the lock, so the second one finds the claim and sends nothing.
  def perform(marketing_action_id)
    action = Marketing::Action.find_by(id: marketing_action_id)
    return if action.nil?

    action.with_lock do
      next unless Marketing::Action.alive_for_reconnect_notice.exists?(id: action.id)

      CreatorMailer.marketing_x_reconnect(marketing_action_id: action.id).deliver_later
      action.update!(reconnect_notified_at: Time.current)
    end
  end
end
