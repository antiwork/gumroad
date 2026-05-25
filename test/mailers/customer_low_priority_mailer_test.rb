# frozen_string_literal: true

require "test_helper"

# Migrated from spec/mailers/customer_low_priority_mailer_spec.rb. The original
# spec used 86 FactoryBot references across many subscription, preorder, and
# review-reminder paths. This fixtures-only port covers a representative set
# of public mailer methods, asserting the recipient / subject / from headers
# without depending on the full premailer / Vite asset pipeline.
class CustomerLowPriorityMailerTest < ActionMailer::TestCase
  include Rails.application.routes.url_helpers

  def default_url_options
    { host: DOMAIN, protocol: PROTOCOL }
  end

  setup do
    @seller = users(:named_seller)
    Rails.cache.write("creator_mailer_level_#{@seller.id}", :level_1)
  end

  # --- chargeback_notice_to_customer ----------------------------------------

  test "chargeback_notice_to_customer addresses the disputed purchase email" do
    dispute = disputes(:resolve_still_active_dispute)
    purchase = dispute.disputable
    mail = CustomerLowPriorityMailer.chargeback_notice_to_customer(dispute.id)

    assert_equal [purchase.email], mail.to
    assert_equal "Regarding your recent dispute.", mail.subject
    assert_includes mail.body.encoded, "Regarding your recent dispute."
  end

  # --- bundle_content_updated -----------------------------------------------

  test "bundle_content_updated addresses the buyer and uses the seller subject" do
    purchase = purchases(:audience_purchase)
    mail = CustomerLowPriorityMailer.bundle_content_updated(purchase.id)

    assert_equal [purchase.email], mail.to
    assert_includes mail.subject, "just added content to"
    assert_includes mail.subject, purchase.link.name
  end

  # --- already_subscribed_checkout_attempt ----------------------------------

  test "already_subscribed_checkout_attempt addresses the existing subscriber" do
    # Use a fixture subscription wired to named_seller_product so the seller
    # mailer-level cache stub above takes effect.
    subscription = subscriptions(:named_seller_product_subscription)
    # The subscription fixture is minimal; set email + last_payment_option via
    # update_columns to dodge model validations.
    subscription.update_columns(
      user_requested_cancellation_at: nil,
      cancelled_at: nil,
      deactivated_at: nil
    )
    # The mailer reads @subscription.email which falls through to the
    # original_purchase's email; the subscription fixture doesn't have one,
    # so stub on the Subscription instance via override.
    # Capture the original Subscription#email UnboundMethod and restore it,
    # rather than `remove_method`-ing — `:email` is defined directly on
    # Subscription, so removing strips the real implementation and leaks
    # `undefined local variable or method 'email' for an instance of Subscription`
    # into sibling tests.
    orig_email = Subscription.instance_method(:email)
    Subscription.define_method(:email) { "subscriber@example.com" }
    begin
      mail = CustomerLowPriorityMailer.already_subscribed_checkout_attempt(subscription.id)
      assert_equal ["subscriber@example.com"], mail.to
      assert_equal "Someone tried to purchase a membership you already have", mail.subject
    ensure
      Subscription.define_method(:email, orig_email)
    end
  end
end
