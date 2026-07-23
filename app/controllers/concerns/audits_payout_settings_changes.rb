# frozen_string_literal: true

# Payout settings are the top target for account-takeover monetization
# (redirecting a seller's earnings to an attacker's bank account). Team
# members with the admin role can change these settings — not just the
# account owner — so we leave an audit note on the seller account whenever
# the person making the change is not the owner. Support and risk teams can
# then see exactly who changed payout details and when.
module AuditsPayoutSettingsChanges
  extend ActiveSupport::Concern

  private
    # Call this AFTER a payout-affecting mutation has completed, at each
    # point where a mutation finishes (not just at the end of the action) so
    # a later validation failure in the same request can neither suppress
    # the note for a change that already happened nor record a note for a
    # change that never happened.
    #
    # The note is best-effort: the payout change has already been persisted
    # by the time we get here, so a failure to write the note must not turn
    # the response into an error — the caller would retry an operation that
    # already succeeded, and the note would still be missing. Instead we
    # notify Sentry so a missing audit entry gets investigated.
    #
    # Idempotent within a request: an action that mutates several payout
    # surfaces produces a single note.
    def log_payout_settings_update_by_non_owner(description = "Payout settings updated")
      return if logged_in_user == current_seller
      return if @_payout_settings_audit_note_created

      current_seller.comments.create!(
        author_id: logged_in_user.id,
        comment_type: Comment::COMMENT_TYPE_NOTE,
        content: "#{description} by team admin #{logged_in_user.email}"
      )
      @_payout_settings_audit_note_created = true
    rescue => e
      ErrorNotifier.notify(e, context: { seller_id: current_seller.id, actor_id: logged_in_user.id })
    end
end
