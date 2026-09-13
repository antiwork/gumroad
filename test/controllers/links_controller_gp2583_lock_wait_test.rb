# frozen_string_literal: true

require "test_helper"

# Pins the lock-wait branch of LinksController#update: a save that waits past
# innodb_lock_wait_timeout answers 409 product_save_busy with a Retry-After
# instead of the catch-all's 422 "refresh the page and try again", and reports
# to Sentry once per product per window rather than once per request.
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
    # The message matters, not just the status: the catch-all renders JSON too,
    # but with the refresh copy — the one action that repeats the same timeout.
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

    # Pins the atomic claim: the window key must carry its own expiry, because
    # the suppression is only safe while the window ends on its own.
    assert $redis.ttl("editor_save_lock_contention:#{@product.id}").positive?
  end

  test "a window key that outlived its window's TTL is re-armed instead of suppressing the product's reports" do
    Link.any_instance.stubs(:lock!).raises(ActiveRecord::LockWaitTimeout)
    ErrorNotifier.expects(:notify).once.with(instance_of(ActiveRecord::LockWaitTimeout), anything)

    key = "editor_save_lock_contention:#{@product.id}"
    # The state a window that expires mid-request leaves behind: a counter with no
    # TTL. A claim that can only fail while the key exists would then report
    # nothing for this product ever again.
    $redis.set(key, 4)
    assert_equal(-1, $redis.ttl(key))

    put :update, params: @base_params, as: :json
    assert_response :conflict
    assert $redis.ttl(key).positive?, "expected the stale counter to be re-armed with an expiry"

    # And the re-armed window must still end on schedule: a client that keeps
    # looping must not be able to push it out. Shortening it first makes the
    # reset distinguishable from the passage of a second.
    $redis.expire(key, 5)
    put :update, params: @base_params, as: :json
    assert_response :conflict
    assert_operator $redis.ttl(key), :<=, 5

    # Once that window ends, the product reports again.
    $redis.del(key)
    put :update, params: @base_params, as: :json
    assert_response :conflict
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

  test "a Redis failure while reporting still answers the retryable 409 instead of a 500" do
    Link.any_instance.stubs(:lock!).raises(ActiveRecord::LockWaitTimeout)
    ErrorNotifier.expects(:notify).never
    $redis.stubs(:incr).raises(Redis::CannotConnectError)

    put :update, params: @base_params, as: :json

    assert_response :conflict
    assert_equal "product_save_busy", response.parsed_body["error_code"]
  end
end
