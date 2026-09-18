# frozen_string_literal: true

class SendMarketingXReconnectEmailJob
  class NewEligibleActionsError < StandardError; end

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
    unless pending_ids.any? { deliver(_1) }
      # New candidates may have had their enqueue suppressed by this job's lock.
      # Sidekiq retries after the unique middleware releases that lock.
      raise NewEligibleActionsError if eligible_for(seller).where.not(id: pending_ids).exists?
      return
    end

    # Re-scan rather than settle the ids captured before delivery. A product cancelled mid-send
    # drops out of the scope and is not consumed, and one that failed mid-send is covered by the
    # mail just sent — its own enqueue was discarded by this job's uniqueness lock, so leaving it
    # eligible would strand it with nothing queued to pick it up.
    seller.with_lock { eligible_for(seller).update_all(reconnect_notified_at: Time.current) }
  end

  private
    def deliver(marketing_action_id)
      CreatorMailer.marketing_x_reconnect(marketing_action_id:).deliver_now.is_a?(Mail::Message)
    end

    def eligible_for(seller)
      Marketing::Action.alive_for_reconnect_notice.where(user_id: seller.id).order(:id)
    end
end
