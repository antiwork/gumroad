# frozen_string_literal: true

module User::Comments
  extend ActiveSupport::Concern

  # Records a payout note on the user's account.
  #
  # `seller_visible` decides whether the note may be rendered to the seller in the banner on
  # their Payouts page. Pass `false` for notes written for support or for our own bookkeeping —
  # anything phrased in the third person ("the seller ...") or describing internal machinery.
  # See PayoutNoteVisibility.
  #
  # `json_data` carries structured fields readers key off (which bank row a rejection names, the
  # Stripe error code). Pass them here rather than saving them afterwards: a note is visible to
  # its readers the moment it is inserted, so a second save leaves a window where the note exists
  # without its attribution and gets read as an unattributed legacy note.
  def add_payout_note(content:, seller_visible: true, json_data: {})
    comments.create!(
      content:,
      author_id: GUMROAD_ADMIN_ID,
      comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE,
      json_data: json_data.stringify_keys.merge(PayoutNoteVisibility::SELLER_VISIBLE_FLAG => seller_visible)
    )
  end

  # The newest payout note this seller may actually be shown, or nil.
  #
  # Visibility lives in the comment's json_data, which MySQL cannot filter on usefully, so the
  # newest notes are walked in memory. The scan is capped for the same reason the Payouts banner
  # caps it: an account can carry a long tail of internal breadcrumbs, and a seller-facing note
  # buried under that many newer ones is too stale to matter.
  def latest_seller_visible_payout_note
    recent_payout_notes.find { |note| PayoutNoteVisibility.seller_visible?(note) }
  end

  # The marked Stripe payout-setup-rejection note, or nil. Queried independently of
  # recent_payout_notes' MAX_NOTES_SCANNED cap because this wants one specific note, which other
  # payout notes can push past row 25 while it is still the live rejection blocking the seller.
  def latest_payout_setup_rejection_note
    comments.with_type_payout_note
            .alive
            .where(author_id: GUMROAD_ADMIN_ID)
            .where("json_data LIKE ?", "%#{StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG}%")
            .order(created_at: :desc, id: :desc)
            .find { |note| note.json_data[StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG] == true }
  end

  # The newest payout note on the account, seller-facing or internal.
  #
  # Same scoping and ordering as latest_seller_visible_payout_note on purpose — the payout pipeline
  # compares the two to decide whether a note it is about to write would repeat the newest one, and
  # a different `alive`/author filter or ordering between them would have it comparing different
  # rows.
  def latest_payout_note
    recent_payout_notes.first
  end

  private
    def recent_payout_notes
      comments.with_type_payout_note
              .alive
              .where(author_id: GUMROAD_ADMIN_ID)
              .order(created_at: :desc, id: :desc)
              .limit(PayoutNoteVisibility::MAX_NOTES_SCANNED)
    end
end
