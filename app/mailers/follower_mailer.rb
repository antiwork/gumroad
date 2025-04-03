# frozen_string_literal: true

class FollowerMailer < ApplicationMailer
  layout "layouts/email"
  default from: "Gumroad <noreply@#{FOLLOWER_CONFIRMATION_MAIL_DOMAIN}>"

  def confirm_follower(followed_user_id, follower_id)
    @follower = Follower.find(follower_id)
    @followed_username = User.find(followed_user_id).name_or_username
    @confirm_follow_url = confirm_follow_url(@follower.external_id)

    mail to: @follower.email,
         subject: "Please confirm your follow request.",
         delivery_method_options: MailerInfo.random_delivery_method_options(domain: :followers)
  end
end
