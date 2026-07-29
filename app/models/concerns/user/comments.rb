# frozen_string_literal: true

module User::Comments
  extend ActiveSupport::Concern

  # Records a payout note on the user's account.
  #
  # `seller_visible` decides whether the note may be rendered to the seller in the banner on
  # their Payouts page. Pass `false` for notes written for support or for our own bookkeeping —
  # anything phrased in the third person ("the seller ...") or describing internal machinery.
  # See PayoutNoteVisibility.
  def add_payout_note(content:, seller_visible: true)
    comments.create!(
      content:,
      author_id: GUMROAD_ADMIN_ID,
      comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE,
      json_data: { PayoutNoteVisibility::SELLER_VISIBLE_FLAG => seller_visible }
    )
  end

  # The newest payout note this seller may actually be shown, or nil.
  #
  # Visibility lives in the comment's json_data, which MySQL cannot filter on usefully, so the
  # newest notes are walked in memory. The scan is capped for the same reason the Payouts banner
  # caps it: an account can carry a long tail of internal breadcrumbs, and a seller-facing note
  # buried under that many newer ones is too stale to matter.
  def latest_seller_visible_payout_note
    comments.with_type_payout_note
            .alive
            .where(author_id: GUMROAD_ADMIN_ID)
            .order(created_at: :desc, id: :desc)
            .limit(PayoutNoteVisibility::MAX_NOTES_SCANNED)
            .find { |note| PayoutNoteVisibility.seller_visible?(note) }
  end
end
