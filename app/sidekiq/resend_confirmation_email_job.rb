# frozen_string_literal: true

# Re-sends a user's account-confirmation email after first clearing any stale
# SendGrid deliverability suppressions for the target address.
#
# Why the unsuppress step: a one-off transient delivery failure (greylisting, a
# receiving-server timeout, or DNS still propagating on a brand-new domain) can
# land an address on SendGrid's bounce or block suppression list. Once it's
# there, every later send to that address is silently dropped *before* it goes
# out — so a plain resend never reaches the user, and a brand-new seller can be
# locked out of confirming their account with no visible cause. Clearing the
# deliverability lists first lets the resend actually deliver.
#
# We only ever clear the bounce/block lists — never spam_reports or global
# unsubscribes, which record a person's explicit choice not to hear from us and
# must be respected.
#
# The work runs in the background (rather than inline in the request) so a slow
# or unavailable SendGrid API can't add latency to, or fail, the user-facing
# resend action.
class ResendConfirmationEmailJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  DELIVERABILITY_SUPPRESSION_LISTS = [:bounces, :blocks].freeze

  def perform(user_id)
    user = User.alive.find_by(id: user_id)
    return if user.nil?
    # The user may have confirmed between requesting the resend and this job
    # running; if there's nothing left to confirm, don't send anything.
    return if user.confirmed? && user.unconfirmed_email.blank?

    # For an email change awaiting re-confirmation the link goes to the pending
    # address; otherwise it goes to the account's current email.
    address = user.unconfirmed_email.presence || user.email

    # Best-effort: the send is the critical payload. If SendGrid's suppression API
    # is down, raising here would burn the job's retries and the user would never
    # get the email — the exact silent failure this job exists to prevent. An
    # address that wasn't suppressed loses nothing; a suppressed one is no worse
    # off than before and gets cleared by the nightly stale-suppression sweep.
    begin
      EmailSuppressionManager.new(address).remove_from_lists(DELIVERABILITY_SUPPRESSION_LISTS)
    rescue => e
      ErrorNotifier.notify(e, user_id: user.id)
    end

    user.send_confirmation_instructions
  end
end
