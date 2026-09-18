# frozen_string_literal: true

class SendMarketingXReconnectEmailJob
  include Sidekiq::Job
  # Keyed on the seller, not the action: one notice covers every product they have blocked,
  # so two blocked products must not mail them twice.
  sidekiq_options queue: :low, lock: :until_executed

  def perform(seller_id)
    seller = User.find_by(id: seller_id)
    return if seller.nil?

    pending_ids = seller.with_lock { eligible_for(seller).pluck(:id) }
    return if pending_ids.empty?

    # Delivery stays outside the lock: it is an SMTP call, and holding the seller's rows across
    # it would block approve, cancel and post until SMTP times out. An action that leaves the
    # scope mid-send makes the mailer decline, so fall through to the next one rather than
    # finishing with the seller unnotified.
    return unless pending_ids.any? { deliver(_1) }

    # Re-read rather than trust the ids: a product cancelled mid-send must not be consumed.
    seller.with_lock do
      eligible_for(seller).where(id: pending_ids).update_all(reconnect_notified_at: Time.current)
    end
  end

  private
    def deliver(marketing_action_id)
      CreatorMailer.marketing_x_reconnect(marketing_action_id:).deliver_now.is_a?(Mail::Message)
    end

    def eligible_for(seller)
      Marketing::Action.alive_for_reconnect_notice.where(user_id: seller.id).order(:id)
    end
end
