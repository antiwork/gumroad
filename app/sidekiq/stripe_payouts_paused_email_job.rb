# frozen_string_literal: true

# Sends the "payouts paused" email for a Stripe-initiated pause, but only after
# a debounce delay (see StripeMerchantAccountManager::PAYOUTS_PAUSE_EMAIL_DEBOUNCE_DELAY).
# Stripe sometimes disables payouts for a routine re-verification and re-enables
# them minutes later; pausing internally must stay instant for money safety, but
# emailing the seller about a blip that resolves itself before they even open
# the mail only causes alarm. So the webhook handler schedules this job instead
# of enqueueing the mailer directly, and this job re-checks the account when it
# runs: if the pause already resolved, no email is sent.
class StripePayoutsPausedEmailJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id, merchant_account_id, email_type, claim_token)
    user = User.find(user_id)
    merchant_account = MerchantAccount.find(merchant_account_id)

    email_to_send = nil
    # Take the same per-user lock the webhook handler uses so we can't race a
    # concurrent pause/resume webhook while deciding whether to email.
    user.with_lock do
      merchant_account.reload
      # A newer claim token means payouts resumed and were paused again after
      # this job was scheduled; the job scheduled for that newer pause owns the
      # email now, so this stale job must not send (or we'd double-email).
      next unless merchant_account.stripe_payouts_pause_email_claim_token == claim_token

      if user.payouts_paused_internally? && user.payouts_paused_by_source == User::PAYOUT_PAUSE_SOURCE_STRIPE
        email_to_send = email_type
      else
        # The pause resolved before the debounce window elapsed (a verification
        # blip, or an admin resumed the account) — skip the email entirely, and
        # release the claim so a later, sustained pause emails the seller as if
        # this never happened. (A Stripe-side resume already clears these, but
        # a non-Stripe resume does not, so clear them here too.)
        merchant_account.update!(stripe_payouts_pause_email_sent: nil, stripe_payouts_pause_email_claim_token: nil)
      end
    end

    case email_to_send
    when "action_required"
      MerchantRegistrationMailer.stripe_payouts_disabled(user.id).deliver_later
    when "under_review"
      MerchantRegistrationMailer.stripe_payouts_under_review(user.id).deliver_later
    end
  end
end
