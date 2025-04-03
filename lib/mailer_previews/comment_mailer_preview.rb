# frozen_string_literal: true

class CommentMailerPreview < ActionMailer::Preview
  def notify_seller_of_new_comment
    CommentMailer.notify_seller_of_new_comment(Comment.roots.last&.id)
  end
end
