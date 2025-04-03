# frozen_string_literal: true

class EmailDeliveryObserver
  def self.delivered_email(message)
    EmailDeliveryObserver::HandleEmailEvent.perform(message)
    EmailDeliveryObserver::HandleCustomerEmailInfo.perform(message)
  end
end
