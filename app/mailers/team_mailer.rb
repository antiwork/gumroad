# frozen_string_literal: true

class TeamMailer < ApplicationMailer
  include ActionView::Helpers::SanitizeHelper

  layout "layouts/email"

  # The inviter writes their own display name, and this email reaches someone who may never have
  # heard of them. The subject and the fallback identity are ours; the name reaches the body only
  # once the seller has been reviewed, since the name is where the scam copy goes.
  def invite(team_invitation)
    @team_invitation = team_invitation
    @seller = team_invitation.seller
    @seller_email = @seller.email
    @seller_username = @seller.username
    @seller_name = TeamInvitationThrottle.trusted_sender?(@seller) ? sanitize(@seller.display_name) : @seller_email
    @subject = "You've been invited to join #{@seller_username} on Gumroad"

    mail(
      from: NOREPLY_EMAIL_WITH_NAME,
      to: @team_invitation.email,
      reply_to: @seller.email,
      subject: @subject
    )
  end

  def invitation_accepted(team_membership)
    @team_membership = team_membership
    @user = team_membership.user
    @seller = team_membership.seller
    @user_name = sanitize(@user.display_name(prefer_email_over_default_username: true))
    @subject = "#{@user_name} has accepted your invitation"

    mail(
      from: NOREPLY_EMAIL_WITH_NAME,
      to: @seller.email,
      reply_to: @user.email,
      subject: @subject
    )
  end
end
