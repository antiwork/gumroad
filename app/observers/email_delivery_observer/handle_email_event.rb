# frozen_string_literal: true

module EmailDeliveryObserver::HandleEmailEvent
  extend self

  def perform(message)
    message.to.each do |email|
      EmailEvent.log_send_events(email, message.date)
    rescue => e
      Rails.logger.error "Error logging email event - #{email} - #{e.message}"
    end
  end
end
