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
end
