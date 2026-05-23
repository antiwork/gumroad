# frozen_string_literal: true

require "test_helper"

class HandlePaypalEventWorkerTest < ActiveSupport::TestCase
  test "constructs a PaypalEventHandler with the params and calls handle_paypal_event" do
    params = { id: rand(10_000) }

    handler_mock = Minitest::Mock.new
    handler_mock.expect(:handle_paypal_event, nil)

    received_params = nil
    PaypalEventHandler.stub(:new, ->(p) { received_params = p; handler_mock }) do
      HandlePaypalEventWorker.new.perform(params)
    end

    assert_equal params, received_params
    handler_mock.verify
  end
end
