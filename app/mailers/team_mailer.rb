# frozen_string_literal: true

class TeamMailer < ApplicationMailer
  include ActionView::Helpers::SanitizeHelper

  layout "layouts/email"

  # The inviter writes their own display name, and this email goes to someone who may never have heard of
  # them or of Gumroad. A ring of throwaway accounts put a fake bank-charge notice and a callback number in
  # the name and sent 504k of these (gp#2762). So the subject is ours, and the name only appears once the
  # seller has been reviewed; until then the inviter is identified by their email, which they cannot write
  # scam copy into.
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
