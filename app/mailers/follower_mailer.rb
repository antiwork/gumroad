# frozen_string_literal: true

class FollowerMailer < ApplicationMailer
  layout "layouts/email"
  default from: "Gumroad <noreply@#{FOLLOWER_CONFIRMATION_MAIL_DOMAIN}>"

  around_deliver :hold_back_for_retired_newsletter

  def confirm_follower(followed_user_id, follower_id)
    @follower = Follower.find(follower_id)
    @followed_username = User.find(followed_user_id).name_or_username
    @confirm_follow_url = confirm_follow_url(@follower.external_id)

    mail to: @follower.email,
         subject: "Please confirm your follow request.",
         delivery_method_options: MailerInfo.random_delivery_method_options(domain: :followers, to: @follower.email)
  end

  private
    # A request queued before the newsletter retired is ordered at the handoff, like the newsletter's posts:
    # retire! waits for one being sent, and one sent after it is dropped.
    def hold_back_for_retired_newsletter(&deliver)
      seller_id = @follower&.followed_id
      return deliver.call unless seller_id && FeatureAnnouncementNewsletterCutover.covers?(seller_id)

      FeatureAnnouncementNewsletterCutover.admit_newsletter_handoff(seller_id, &deliver)
    rescue FeatureAnnouncementNewsletterCutover::Retired
      Rails.logger.info("[FollowerMailer] Dropped the confirmation request for follower #{@follower.id}: newsletter retired")
    end
end
