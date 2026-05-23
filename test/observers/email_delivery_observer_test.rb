# frozen_string_literal: true

require "test_helper"

class EmailDeliveryObserverTest < ActiveSupport::TestCase
  test ".delivered_email forwards the message to each registered handler" do
    message = Object.new

    handle_email_event_mock = Minitest::Mock.new
    handle_email_event_mock.expect(:perform, true, [message])

    handle_customer_email_info_mock = Minitest::Mock.new
    handle_customer_email_info_mock.expect(:perform, true, [message])

    EmailDeliveryObserver::HandleEmailEvent.stub(:perform, ->(m) { handle_email_event_mock.perform(m) }) do
      EmailDeliveryObserver::HandleCustomerEmailInfo.stub(:perform, ->(m) { handle_customer_email_info_mock.perform(m) }) do
        EmailDeliveryObserver.delivered_email(message)
      end
    end

    handle_email_event_mock.verify
    handle_customer_email_info_mock.verify
  end
end
