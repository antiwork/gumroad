# frozen_string_literal: true

# Decides whether a `payout_note` comment may be shown to the seller on their Payouts page.
#
# `payout_note` comments do two unrelated jobs. Some are written FOR the seller ("Your payout on
# July 3 was skipped because your balance of $8 was below the $10 minimum"), and the Payouts page
# renders the newest one verbatim in a banner. Others are internal breadcrumbs written for support
# and for our own retry machinery ("Automated Stripe payout-setup retry stopped: ... The seller has
# been emailed and has to re-enter the code."). Nothing in the record distinguished the two, so the
# page rendered whichever was newest and sellers ended up reading staff copy about themselves in the
# third person.
#
# The distinction is now recorded when the note is written: `add_payout_note` stores a
# `seller_visible` boolean in the comment's json_data, and this module is the single place that
# reads it. Writers that record internal state pass `seller_visible: false`.
#
# Notes written before that flag existed have no value stored, so they fall back to a fixed list of
# the internal note shapes we have ever written. That list is closed — new internal notes get the
# flag instead of an entry here — and exists only so historical rows keep behaving correctly.
module PayoutNoteVisibility
  SELLER_VISIBLE_FLAG = "seller_visible"

  # Prefixes/contents of internal-only payout notes written before the flag existed.
  #
  # "Payout via PayPal" is in here because the Payouts page has always excluded those notes from
  # the banner (it used a `content LIKE 'Payout via PayPal%'` filter); keeping them out preserves
  # that behaviour for legacy rows rather than changing what sellers see.
  def self.legacy_internal_note_prefixes
    [
      StripeMerchantAccountManager::BANK_SYNC_FAILURE_NOTE_PREFIX,
      StripeMerchantAccountManager::POSTAL_CODE_FAILURE_NOTE_PREFIX,
      "[PAYOUT][DRIFT]",
      "Payout via PayPal",
      RetryStripeRejectedPayoutSetupForSellerJob::RESOLVED_NOTE,
      RetryStripeRejectedPayoutSetupForSellerJob::GAVE_UP_NOTE,
      RetryStripeRejectedPayoutSetupForSellerJob::SWITCHED_OFF_STRIPE_NOTE,
      RetryStripeRejectedPayoutSetupForSellerJob::CONNECTED_STRIPE_NOTE,
      RetryStripeRejectedPayoutSetupForSellerJob::ACCOUNT_BLOCKED_NOTE,
      RetryStripeRejectedPayoutSetupForSellerJob::BANK_FORMAT_REJECTION_NOTE,
    ].freeze
  end

  def self.seller_visible?(note)
    # The flag is read straight out of json_data rather than through a json_data accessor, because
    # those accessors fall back to their default when the stored value is blank and `false` counts
    # as blank — an explicitly hidden note would read back as "no opinion".
    flag = note.json_data[SELLER_VISIBLE_FLAG]
    return flag == true unless flag.nil?

    !legacy_internal_note?(note.content.to_s)
  end

  # Case-insensitive because the database filter this replaces was a MySQL LIKE on a
  # case-insensitive collation, and one writer capitalizes the processor name itself
  # ("Payout via Paypal on ... failed because ...").
  def self.legacy_internal_note?(content)
    downcased = content.downcase
    legacy_internal_note_prefixes.any? { |prefix| downcased.start_with?(prefix.downcase) }
  end
end
