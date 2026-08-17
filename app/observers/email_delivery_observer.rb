# frozen_string_literal: true

class EmailDeliveryObserver
  def self.delivered_email(message)
    EmailDeliveryObserver::HandleCustomerEmailInfo.perform(message)
  end
end
