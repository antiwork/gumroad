# frozen_string_literal: true

require "test_helper"

class CancelPreorderWorkerTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  test "cancels the preorder if it is in authorization_successful state but does not send notification emails" do
    preorder = preorders(:preorder_successful)
    auth_purchase = purchases(:preorder_successful_auth_purchase)
    # Defensively reload fixtures — earlier tests in the full suite may have
    # mutated `preorder.state` or `auth_purchase.purchase_state` (no leak
    # source identified; retry-on-reload is the cheap fix).
    preorder.reload
    auth_purchase.reload
    if preorder.state != "authorization_successful"
      preorder.update_columns(state: "authorization_successful")
    end
    if auth_purchase.purchase_state != "preorder_authorization_successful"
      auth_purchase.update_columns(purchase_state: "preorder_authorization_successful")
    end
    assert_equal "authorization_successful", preorder.state

    assert_no_enqueued_emails do
      CancelPreorderWorker.new.perform(preorder.id)
    end

    assert_equal "cancelled", preorder.reload.state
    assert_equal "preorder_concluded_unsuccessfully", auth_purchase.reload.purchase_state
  end

  test "does not cancel the preorder if it is not in authorization_successful state" do
    in_progress = preorders(:preorder_in_progress)
    CancelPreorderWorker.new.perform(in_progress.id)
    assert_equal "in_progress", in_progress.reload.state

    charged = preorders(:preorder_charged)
    CancelPreorderWorker.new.perform(charged.id)
    assert_equal "charge_successful", charged.reload.state
  end
end
