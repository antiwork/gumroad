# frozen_string_literal: true

class TeamMailer < ApplicationMailer
  include ActionView::Helpers::SanitizeHelper

  layout "layouts/email"

  def invite(team_invitation)
    @team_invitation = team_invitation
    @seller = team_invitation.seller
    @seller_name = sanitize(team_invitation.seller.display_name)
    @seller_email = team_invitation.seller.email
    @seller_username = team_invitation.seller.username
    @subject = "#{@seller_name} has invited you to join #{@seller_username}"

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
