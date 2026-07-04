# frozen_string_literal: true

# Runs the dispute-rate refund-policy enforcement check for the seller of a purchase.
#
# This runs as a background job (instead of inline in the dispute webhook handler) on
# purpose: the dispute is marked formalized before per-purchase processing, so if
# enforcement raised inline, a webhook retry would return early on the "already
# formalized" guard and the seller would never get enforced. As a job, a failure here
# retries independently via Sidekiq without blocking or being blocked by the dispute
# webhook. The enforcement method itself is idempotent (it no-ops once the seller is
# already enforced), so retries and duplicate enqueues are safe.
class EnforceRefundPolicyForSellerJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(purchase_id)
    Purchase.find(purchase_id).enforce_refund_policy_for_seller_based_on_dispute_rate!
  end
end
