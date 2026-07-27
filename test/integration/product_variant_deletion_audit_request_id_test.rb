# frozen_string_literal: true

require "test_helper"

# Proves a caller cannot choose what lands in the deletion audit's correlation
# column.
#
# This has to be an INTEGRATION test rather than a controller test: the value
# originates in ActionDispatch::RequestId, which is middleware, and controller
# tests bypass the middleware stack — `request.request_id` is nil there (verified,
# not assumed), so a controller test would pass whether or not the digest existed.
#
# The risk being closed: Rails' RequestId takes the client's `X-Request-Id` header
# when present and only strips punctuation from it
# (`request_id.gsub(/[^\w\-@]/, "").first(255)`). Persisting that verbatim would
# let a caller write up to 255 characters of chosen text into an audit table, or
# reuse another request's id so unrelated audit rows appear correlated.
class ProductVariantDeletionAuditRequestIdTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    # The test environment keeps CSRF protection on so request tests exercise it
    # like production; integration tests don't get the controller-test bypass, so
    # turn it off for these two requests only.
    @_previous_allow_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = false

    @seller = create_user
    @product = create_product_with_pdf_file(user: @seller)
    @category = create_variant_category(link: @product, title: "Versions")
    @variant = create_variant(variant_category: @category, name: "Plain version")
    sign_in @seller
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @_previous_allow_forgery_protection
  end

  test "a caller-supplied X-Request-Id is digested, never stored verbatim" do
    hostile = "z" * 255

    assert_difference -> { ProductVariantDeletionAudit.count }, 1 do
      post "/links/#{@product.unique_permalink}",
           params: { id: @product.unique_permalink, name: @product.name, variants: [] },
           headers: { "X-Request-Id" => hostile, "HOST" => "app.test.gumroad.com" },
           as: :json
      assert_response :success
    end

    audit = ProductVariantDeletionAudit.last
    assert_not_equal hostile, audit.correlation_id
    assert_not_includes audit.correlation_id.to_s, "zzzzzzzz"
    assert_match(/\A[0-9a-f]{64}\z/, audit.correlation_id)
    # It is the digest of what the caller sent, so rows from one request still
    # group together — the value is unforgeable, not random.
    assert_equal AuditCorrelationId.for(hostile), audit.correlation_id
  end

  # The digest must differ per request id, so rows from different requests do not
  # collapse together. Asserted on the helper directly: the end-to-end path is
  # already proven by the test above, and driving a second full save here fights
  # the fixture (the first save removes the product's only grouping, so a repeat
  # save deletes nothing).
  test "the digest is stable per request id and differs across request ids" do
    first = AuditCorrelationId.for("first-request")
    second = AuditCorrelationId.for("second-request")

    assert_equal first, AuditCorrelationId.for("first-request")
    assert_not_equal first, second
    assert_match(/\A[0-9a-f]{64}\z/, first)
    assert_match(/\A[0-9a-f]{64}\z/, second)
    # No request id is recorded honestly as nil rather than a fake correlation.
    assert_nil AuditCorrelationId.for(nil)
    assert_nil AuditCorrelationId.for("")
  end
end
