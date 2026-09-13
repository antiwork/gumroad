# frozen_string_literal: true

require "test_helper"

# Pins gumroad-private#2583: one product's editor save was retried by a looping
# client for five hours — 1,293 POSTs, each waiting the full 50s
# `innodb_lock_wait_timeout` before a 422 carrying the catch-all's "Something
# went wrong while saving your changes. Please refresh the page and try again"
# copy. Two things were wrong with that answer. A reload re-enters the lock
# queue the request just timed out on, which is the opposite of backing off;
# and `ErrorNotifier.notify` ran once per event, so one stuck product became the
# org's top production issue and buried that day's real regressions.
class LinksControllerGp2583LockWaitTest < ActionController::TestCase
  tests LinksController

  setup do
    @seller = create_user(name: "Seller", payment_address: "seller-pay-#{SecureRandom.hex(4)}@example.com")
    @logged_in_user = create_user
    create_team_membership(user: @logged_in_user, seller: @seller, role: TeamMembership::ROLE_ADMIN)
    cookies.encrypted[:current_seller_id] = @seller.id
    sign_in @logged_in_user

    @product = create_product(user: @seller)
    @base_params = { id: @product.unique_permalink, name: @product.name }
  end

  test "a save that waits past innodb_lock_wait_timeout answers 409 product_save_busy, not the generic refresh copy" do
    Link.any_instance.stubs(:lock!).raises(ActiveRecord::LockWaitTimeout)
    ErrorNotifier.expects(:notify).with(instance_of(ActiveRecord::LockWaitTimeout), anything)

    put :update, params: @base_params, as: :json

    assert_response :conflict
    body = response.parsed_body
    assert_equal "product_save_busy", body["error_code"]
    assert_equal 5, body["retry_after"]
    assert_equal "5", response.headers["Retry-After"]
    # Assert the message, not just the status: falling through to the catch-all
    # would render JSON too, but with the refresh copy — the one action that
    # guarantees the same timeout again.
    assert_not_includes body["error_message"].to_s, "refresh"
    assert_includes body["error_message"].to_s, "wait"
  end

  test "repeated lock waits on one product report once per window, so a looping client cannot flood the tracker" do
    Link.any_instance.stubs(:lock!).raises(ActiveRecord::LockWaitTimeout)
    ErrorNotifier.expects(:notify).once.with(instance_of(ActiveRecord::LockWaitTimeout), anything)

    3.times do
      put :update, params: @base_params, as: :json
      assert_response :conflict
    end
  end

  test "the report window is per product, so one product's flood cannot silence another product's contention" do
    other_product = create_product(user: @seller)
    Link.any_instance.stubs(:lock!).raises(ActiveRecord::LockWaitTimeout)
    ErrorNotifier.expects(:notify).twice.with(instance_of(ActiveRecord::LockWaitTimeout), anything)

    put :update, params: @base_params, as: :json
    put :update, params: { id: other_product.unique_permalink, name: other_product.name }, as: :json

    assert_response :conflict
  end

  test "a suppressed report still logs a greppable line carrying the occurrence count" do
    Link.any_instance.stubs(:lock!).raises(ActiveRecord::LockWaitTimeout)
    ErrorNotifier.stubs(:notify)

    logged = []
    Rails.logger.stubs(:info).with { |message| logged << message }

    2.times { put :update, params: @base_params, as: :json }

    lines = logged.grep(/product_editor_save_lock_contention/)
    assert_equal 2, lines.size, "expected one log line per lock wait, got: #{logged.inspect}"
    assert_includes lines.last, "occurrences_in_window=2"
  end
end
