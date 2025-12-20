# frozen_string_literal: true

class BalanceTopUpNotificationJob
  include Sidekiq::Job

  sidekiq_options queue: "default", retry: 3

  def perform(balance_top_up_id)
    balance_top_up = BalanceTopUp.find_by(id: balance_top_up_id)
    return if balance_top_up.blank?

    ContactingCreatorMailer.balance_top_up_confirmation(balance_top_up.id).deliver_later(queue: "critical")
  end
end
