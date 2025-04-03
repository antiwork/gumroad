# frozen_string_literal: true

module User::Comments
  extend ActiveSupport::Concern

  def add_payout_note(content:)
    comments.create!(
      content:,
      author_id: GUMROAD_ADMIN_ID,
      comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE
    )
  end
end
