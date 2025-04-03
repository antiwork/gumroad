# frozen_string_literal: true

class CommentMailer < ApplicationMailer
  layout "layouts/email"

  default from: "noreply@#{CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN}"

  def notify_seller_of_new_comment(comment_id)
    @comment = Comment.includes(:commentable).find(comment_id)

    subject = "New comment on #{@comment.commentable.name}"

    mail(
      to: @comment.commentable.seller.form_email,
      subject:,
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :creators)
    )
  end
end
