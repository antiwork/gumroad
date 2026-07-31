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
end
