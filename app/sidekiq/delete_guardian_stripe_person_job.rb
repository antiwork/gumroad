# frozen_string_literal: true

# Retries one guardian Stripe Person deletion that failed during GDPR erasure.
#
# Erasure deletes these outside its transaction, over the network, so a Stripe outage or rate limit
# leaves the adult's name, date of birth and address at Stripe after we have already anonymized our
# own copy — and erasure has no second pass of its own. This job is that second pass: it is the only
# thing standing between a transient Stripe failure and permanently retained third-party PII, so it
# retries for days rather than the usual few minutes.
#
# Idempotent by construction: StripeGuardianManager.delete_person_by_id treats an already-deleted
# Person as success, so a re-run after a partial failure is safe.
class DeleteGuardianStripePersonJob
  include Sidekiq::Job
  sidekiq_options retry: 20, queue: :default

  # Exhausting the retries is the one outcome nobody can be allowed to miss: a third party's identity
  # data stays at Stripe and the erasure request the admin was told to "re-check" has nothing durable
  # to check. Leaves a breadcrumb on the seller as well as notifying, matching
  # HandleNewBankAccountWorker, so the record survives the Sentry event's retention.
  sidekiq_retries_exhausted do |msg, _exception|
    stripe_person_id, stripe_account_id, user_id = msg["args"]
    content = "GDPR erasure incomplete: guardian Stripe person #{stripe_person_id} on account " \
              "#{stripe_account_id} could not be deleted and exhausted Sidekiq retries. The " \
              "guardian's details are still held at Stripe. See Sentry for the underlying error."

    ErrorNotifier.notify(content)

    begin
      User.find_by(id: user_id)&.add_payout_note(content:, seller_visible: false)
    rescue => e
      Rails.logger.error("Failed to record erasure breadcrumb for user #{user_id}: #{e.class}: #{e.message}")
      ErrorNotifier.notify(e)
    end
  end

  def perform(stripe_person_id, stripe_account_id, user_id)
    return if StripeGuardianManager.delete_person_by_id(stripe_person_id, stripe_account_id)

    # False means Stripe no longer has the account, so it cannot be holding the Person. Nothing left
    # to delete and nothing to retry.
    Rails.logger.info(
      "GDPR: Stripe account for guardian person deletion no longer exists (user #{user_id})"
    )
  end
end
