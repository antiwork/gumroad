# frozen_string_literal: true

# Verifies (async) that a recurring purchase registered on a Stripe SetupIntent actually
# carries an RBI e-mandate — Indian cards need one for future off-session renewals, and
# Stripe can complete the setup without creating a Mandate object. The check retrieves the
# setup intent from Stripe, which is why it runs here instead of inline in the buyer-facing
# SCA confirmation request: it is observability only and must not add third-party latency
# to checkout. The unique lock absorbs double confirms for the same purchase. A multi-product
# cart shares one setup intent across its purchases, so one confirm can enqueue a job per
# purchase — the duplicate checks (and any duplicate missing-mandate reports) are expected.
class CheckIndianCardMandateRegistrationJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3, lock: :until_executed

  def perform(purchase_id)
    Purchase.find(purchase_id).check_indian_card_setup_intent_mandate_was_registered
  end
end
