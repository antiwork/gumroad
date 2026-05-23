# frozen_string_literal: true

require "test_helper"

class HandleStripeEventWorkerTest < ActiveSupport::TestCase
  test "without a stripe_connect_account_id, calls StripeEventHandler#handle_stripe_event" do
    id = rand(10_000).to_s

    handler_mock = Minitest::Mock.new
    handler_mock.expect(:handle_stripe_event, nil)

    received_args = nil
    StripeEventHandler.stub(:new, ->(args) { received_args = args; handler_mock }) do
      HandleStripeEventWorker.new.perform(id:, type: "deauthorized")
    end

    assert_equal({ id:, type: "deauthorized" }, received_args)
    handler_mock.verify
  end

  test "with a stripe_connect_account_id, calls StripeEventHandler#handle_stripe_event" do
    id = rand(10_000).to_s

    handler_mock = Minitest::Mock.new
    handler_mock.expect(:handle_stripe_event, nil)

    received_args = nil
    StripeEventHandler.stub(:new, ->(args) { received_args = args; handler_mock }) do
      HandleStripeEventWorker.new.perform(id:, user_id: "acct_1234", type: "deauthorized")
    end

    assert_equal({ id:, user_id: "acct_1234", type: "deauthorized" }, received_args)
    handler_mock.verify
  end
end
